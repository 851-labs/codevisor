import CodevisorClient
import CodevisorCore
import CodevisorScreenSharing
import Foundation
import ScreenSharingRFB

extension ScreenSharingViewerBackend {
  /// A standard VNC server. Discovery performs a handshake to learn the
  /// desktop's name and size (and to surface a bad password early); a
  /// connection is replaced up to three times after video was seen and the
  /// socket dropped, and ends with the server's own message otherwise.
  @MainActor
  public static func vnc(target: ScreenSharingVNCTarget, password: @escaping @Sendable () async -> String?) -> Self {
    vnc(
      target: target, password: password, open: openVNC,
      makeSurface: { session in
        try ScreenSharingVideoSurface(
          mailbox: session.frames, metrics: session.metrics, profile: ScreenSharingDiagnosticProfile.process())
      })
  }

  typealias VNCOpen =
    @Sendable (_ host: String, _ port: UInt16, _ password: String?) async throws -> (
      RFBClient, RFBHandshake.Outcome
    )

  /// TCP, handshake and authentication; the client is closed on any failure.
  static let openVNC: VNCOpen = { host, port, password in
    let transport = try await RFBNetworkTransport.connect(host: host, port: port)
    let client = try RFBClient(transport: transport)
    do {
      return (client, try await client.connect(password: password))
    } catch {
      client.close()
      throw error
    }
  }

  @MainActor
  static func vnc(
    target: ScreenSharingVNCTarget, password: @escaping @Sendable () async -> String?, open: @escaping VNCOpen,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  ) -> Self {
    let runner = VNCScreenSharingViewerRunner(target: target, password: password, open: open, makeSurface: makeSurface)
    return Self(connect: { _ in await runner.connect() }, discover: { try await runner.discover() })
  }
}

/// One pane's VNC connections, one after another, mirroring the native runner's shape.
@MainActor
private final class VNCScreenSharingViewerRunner {
  private let target: ScreenSharingVNCTarget
  private let password: @Sendable () async -> String?
  private let open: ScreenSharingViewerBackend.VNCOpen
  private let makeSurface: @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  private var previous: Task<Void, Never>?

  init(
    target: ScreenSharingVNCTarget, password: @escaping @Sendable () async -> String?,
    open: @escaping ScreenSharingViewerBackend.VNCOpen,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  ) {
    self.target = target
    self.password = password
    self.open = open
    self.makeSurface = makeSurface
  }

  func discover() async throws -> [ServerScreenSharingDisplay] {
    await previous?.value
    try Task.checkCancellation()
    let (client, outcome) = try await open(target.host, target.port, await password())
    client.close()
    let parameters = outcome.parameters
    return [
      ServerScreenSharingDisplay(
        id: target.displayId, name: parameters.name.isEmpty ? target.displayName : parameters.name,
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

  private enum Outcome { case lost, ended(String), cancelled }

  private func run(emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void) async {
    var restarts = 0
    attempts: while !Task.isCancelled {
      switch await attempt(restarts: restarts, emit: emit) {
      case .lost:
        restarts += 1
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
    do {
      (client, outcome) = try await open(target.host, target.port, await password())
    } catch {
      return Task.isCancelled ? .cancelled : .ended(error.localizedDescription)
    }
    let session = VNCScreenSharingSession(client: client, parameters: outcome.parameters)
    let endpoint: ScreenSharingViewerEndpoint
    do {
      endpoint = ScreenSharingViewerEndpoint(session: session, surface: try makeSurface(session))
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
      return ready && restarts < 3 ? .lost : .ended(error.localizedDescription)
    default:
      return .ended(error.localizedDescription)
    }
  }
}
