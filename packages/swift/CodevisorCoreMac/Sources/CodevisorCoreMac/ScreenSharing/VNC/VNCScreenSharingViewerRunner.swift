import CodevisorClient
import ScreenSharing
import Foundation

extension ScreenSharingViewerBackend {
  public typealias VNCOpen = @Sendable () async throws -> (client: RFBClient, outcome: RFBHandshake.Outcome)

  @MainActor
  public static func vnc(
    displayId: String, open: @escaping VNCOpen,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface = {
      try ScreenSharingVideoSurface(mailbox: $0.frames, metrics: $0.metrics)
    }
  ) -> Self {
    let runner = VNCScreenSharingViewerRunner(displayId: displayId, open: open, makeSurface: makeSurface)
    return Self(
      connect: { _ in await runner.connect() }, discover: { try await runner.discover() }, claim: {},
      setVisible: { _ in }, retire: {}, liveStreams: { .finished })
  }
}

@MainActor
final class VNCScreenSharingViewerRunner {
  private let displayId: String
  private let open: ScreenSharingViewerBackend.VNCOpen
  private let setDesktopScale: (@MainActor (Int) async -> Void)?
  private let arbitratedByServer: @MainActor () -> Bool
  private let makeSurface: @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  private var previous: Task<Void, Never>?
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
      endpoint.dropsInjectedInput = false
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
