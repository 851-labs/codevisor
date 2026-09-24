import CodevisorClient
import ScreenSharing
import Foundation

extension ScreenSharingViewerBackend {
  public typealias VNCOpen = @Sendable () async throws -> (client: RFBClient, outcome: RFBHandshake.Outcome)

  /// A VNC server reached through `open` (the loopback server in tests and
  /// the Screen Sharing rig; the product goes through the native backend's
  /// provider switch). Discovery performs a handshake to learn the desktop's
  /// name and size, and the first connection after it reuses that handshake's
  /// connection rather than signing in again (851-2353); a connection is
  /// replaced up to three times after video was seen and the socket dropped,
  /// and ends with the server's own message otherwise. The surface defaults to the one the native backend makes.
  @MainActor
  public static func vnc(
    displayId: String, open: @escaping VNCOpen,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface = {
      try ScreenSharingVideoSurface(
        mailbox: $0.frames, metrics: $0.metrics, profile: ScreenSharingDiagnosticProfile.process())
    }
  ) -> Self {
    let runner = VNCScreenSharingViewerRunner(displayId: displayId, open: open, makeSurface: makeSurface)
    return Self(connect: { _ in await runner.connect() }, discover: { try await runner.discover() })
  }
}

/// One pane's VNC connections, one after another, mirroring the native runner's shape.
@MainActor
final class VNCScreenSharingViewerRunner {
  private let displayId: String
  private let open: ScreenSharingViewerBackend.VNCOpen
  /// Sets the desktop's UI scale through the machine's server (Dynamic Resolution, 851-2340).
  private let setDesktopScale: (@MainActor (Int) async -> Void)?
  /// Whether the machine's server holds the control lease (851-2338); else control is local.
  private let arbitratedByServer: @MainActor () -> Bool
  private let makeSurface: @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  private var previous: Task<Void, Never>?
  /// The connection discovery opened, kept for the next attempt so one connect
  /// signs in once: a Mac account sign-in is a 4096-bit key exchange, and every
  /// connection shows on the Mac as a viewer (851-2353). Closed if unused by the
  /// next discovery or when the runner goes away.
  private var discovered: (client: RFBClient, outcome: RFBHandshake.Outcome)?

  init(
    displayId: String, open: @escaping ScreenSharingViewerBackend.VNCOpen,
    arbitratedByServer: @escaping @MainActor () -> Bool = { false },
    setDesktopScale: (@MainActor (Int) async -> Void)? = nil,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  ) {
    self.displayId = displayId
    self.open = open
    self.setDesktopScale = setDesktopScale
    self.arbitratedByServer = arbitratedByServer
    self.makeSurface = makeSurface
  }

  isolated deinit { discovered?.client.close() }

  func discover() async throws -> [ServerScreenSharingDisplay] {
    await previous?.value
    try Task.checkCancellation()
    discovered?.client.close()
    discovered = nil
    let opened = try await open()
    guard !Task.isCancelled else {
      opened.client.close()
      throw CancellationError()
    }
    discovered = opened
    let parameters = opened.outcome.parameters
    return [
      ServerScreenSharingDisplay(
        id: displayId, name: parameters.name.isEmpty ? "VNC Desktop" : parameters.name,
        width: parameters.width, height: parameters.height)
    ]
  }

  func connect() -> AsyncStream<ScreenSharingViewerEvent> {
    AsyncStream { continuation in
      let pending = previous
      let run = Task { @MainActor [self] in
        await pending?.value
        if !Task.isCancelled {
          await self.run { continuation.yield($0) }
        }
        continuation.finish()
      }
      previous = run
      continuation.onTermination = { _ in run.cancel() }
    }
  }

  /// `stale`: discovery's connection had closed before any video; open a fresh one.
  private enum Outcome { case lost, stale, ended(String), cancelled }

  private func run(emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void) async {
    var restarts = 0
    attempts: while !Task.isCancelled {
      switch await attempt(restarts: restarts, emit: emit) {
      case .lost:
        restarts += 1
        emit(.reconnecting)
      case .stale:
        emit(.reconnecting)
      case .ended(let message):
        emit(.ended(message))
        break attempts
      case .cancelled:
        break attempts
      }
    }
  }

  private func attempt(restarts: Int, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void) async -> Outcome {
    let client: RFBClient
    let outcome: RFBHandshake.Outcome
    let reused = discovered != nil
    if let discovered {
      (client, outcome) = discovered
      self.discovered = nil
    } else {
      do {
        (client, outcome) = try await open()
      } catch {
        return Task.isCancelled ? .cancelled : .ended(error.localizedDescription)
      }
    }
    let session = VNCScreenSharingSession(
      client: client, parameters: outcome.parameters,
      leaseChannel: arbitratedByServer() ? client.controlChannel : nil)
    let endpoint: ScreenSharingViewerEndpoint
    do {
      endpoint = ScreenSharingViewerEndpoint(
        session: session, surface: try makeSurface(session))
      endpoint.setDesktopScale = setDesktopScale
    } catch {
      session.close()
      return .ended(error.localizedDescription)
    }
    var ready = false
    endpoint.onReady = {
      ready = true
      emit(.ready)
    }
    emit(.opened(endpoint))
    let error = await withTaskCancellationHandler {
      await session.outcome()
    } onCancel: {
      Task { @MainActor in endpoint.close() }
    }
    endpoint.close()
    if Task.isCancelled { return .cancelled }
    switch error as? RFBError {
    case .connectionClosed, .transport:
      if !ready, reused { return .stale }
      return ready && restarts < 3 ? .lost : .ended(error.localizedDescription)
    default:
      return .ended(error.localizedDescription)
    }
  }
}
