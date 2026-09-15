import CodevisorClient
import CodevisorScreenSharing
import ComposableArchitecture
import Foundation

/// What a backend tells the viewer about one connection attempt, in order.
/// `opened` may repeat after `reconnecting`; `ended` is terminal and the stream
/// finishes after it. Cancelling the stream is the only way to stop early.
@CasePathable
public enum ScreenSharingViewerEvent: Equatable, Sendable {
  /// New media to render; replaces any previous endpoint, which is already closed.
  case opened(ScreenSharingViewerEndpoint)
  /// The endpoint's first frame reached the screen.
  case ready
  /// Transport loss after video; a fresh `opened` follows, or `ended`.
  case reconnecting
  /// The host revoked or the surface lost the control lease.
  case controlReleased
  /// Terminal, with the message to show.
  case ended(String)
}

/// The seam between the viewer feature and whatever negotiates media. The
/// native implementation talks to the Codevisor server; a future VNC
/// implementation would open a socket. The reducer never learns which.
public struct ScreenSharingViewerBackend: Sendable {
  public var discover: @Sendable () async throws -> [ServerScreenSharingDisplay]
  /// Main-actor because every backend owns main-actor endpoints; the reducer awaits it from its effect.
  public var connect: @MainActor @Sendable (_ displayId: String) -> AsyncStream<ScreenSharingViewerEvent>

  public init(
    discover: @escaping @Sendable () async throws -> [ServerScreenSharingDisplay],
    connect: @escaping @MainActor @Sendable (_ displayId: String) -> AsyncStream<ScreenSharingViewerEvent>
  ) {
    self.discover = discover
    self.connect = connect
  }
}

extension ScreenSharingViewerBackend: TestDependencyKey {
  public static let testValue = ScreenSharingViewerBackend(
    discover: {
      reportIssue("Unimplemented: ScreenSharingViewerBackend.discover")
      return []
    },
    connect: { _ in
      reportIssue("Unimplemented: ScreenSharingViewerBackend.connect")
      return .finished
    })
}

extension DependencyValues {
  /// Installed per pane with `withDependencies`; there is no process-wide live value.
  public var screenSharingViewerBackend: ScreenSharingViewerBackend {
    get { self[ScreenSharingViewerBackend.self] }
    set { self[ScreenSharingViewerBackend.self] = newValue }
  }
}

extension ScreenSharingViewerBackend {
  /// The shipped backend: capabilities, one-shot SDP over authenticated
  /// signaling, 8 s heartbeats, lease-bound media replacement after network
  /// loss (three restarts with the same viewer id), and an authenticated stop
  /// that survives cancellation.
  @MainActor
  public static func native(client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID) -> Self {
    native(
      client: client, workspaceId: workspaceId, paneId: paneId, sleep: { try await Task.sleep(for: $0) },
      makeSession: { try NativeScreenSharingViewingSession.process(connectivity: $0) },
      makeSurface: { session in
        try ScreenSharingVideoSurface(
          mailbox: session.frames, metrics: session.metrics, profile: ScreenSharingDiagnosticProfile.process())
      })
  }

  @MainActor
  static func native(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    makeSession: @escaping @MainActor (ServerScreenSharingConnectivity?) throws -> any NativeScreenSharingMediaSession,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  ) -> Self {
    let runner = NativeScreenSharingViewerRunner(
      client: client, workspaceId: workspaceId, paneId: paneId, sleep: sleep, makeSession: makeSession,
      makeSurface: makeSurface)
    return Self(discover: { try await runner.discover() }, connect: { display in runner.connect(display) })
  }
}

/// One pane's native connections, strictly one after another: a new discovery
/// or connection waits for the previous connection's teardown — including its
/// authenticated stop — so a stop can never overtake the next start.
@MainActor
private final class NativeScreenSharingViewerRunner {
  private let client: any CodevisorServerClienting
  private let workspaceId: UUID
  private let paneId: UUID
  private let sleep: @Sendable (Duration) async throws -> Void
  private let makeSession: @MainActor (ServerScreenSharingConnectivity?) throws -> any NativeScreenSharingMediaSession
  private let makeSurface: @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  private var previous: Task<Void, Never>?

  init(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    makeSession: @escaping @MainActor (ServerScreenSharingConnectivity?) throws -> any NativeScreenSharingMediaSession,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  ) {
    self.client = client
    self.workspaceId = workspaceId
    self.paneId = paneId
    self.sleep = sleep
    self.makeSession = makeSession
    self.makeSurface = makeSurface
  }

  func discover() async throws -> [ServerScreenSharingDisplay] {
    await previous?.value
    try Task.checkCancellation()
    let reply = try await client.screenSharing(request(.capabilities, viewerId: UUID()))
    guard reply.version == 1, ["available", "busy"].contains(reply.status) else {
      throw ViewerError(reply.message ?? "Screen Sharing is unavailable on this Mac.")
    }
    return reply.displays
  }

  func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent> {
    AsyncStream { continuation in
      let pending = previous
      let run = Task { @MainActor [self] in
        await pending?.value
        if !Task.isCancelled {
          await self.run(display: display) { continuation.yield($0) }
        }
        continuation.finish()
      }
      previous = run
      continuation.onTermination = { _ in run.cancel() }
    }
  }

  private enum Outcome { case lost, ended(String), cancelled }

  /// Mutable attempt state shared with the session's callbacks.
  @MainActor
  private final class Attempt {
    var endpoint: ScreenSharingViewerEndpoint?
    var body: Task<Outcome, Never>?
    var ready = false
    var started = false
    var outcome: Outcome?
  }

  private func run(display: String, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void) async {
    let viewerId = UUID()
    var restarts = 0
    var started = false
    var message: String?
    attempts: while !Task.isCancelled {
      let (outcome, attemptStarted) = await attempt(
        viewerId: viewerId, display: display, restarts: restarts, emit: emit)
      started = started || attemptStarted
      switch outcome {
      case .lost:
        restarts += 1
        emit(.reconnecting)
      case .ended(let reason):
        message = reason
        break attempts
      case .cancelled:
        break attempts
      }
    }
    if let message { emit(.ended(message)) }
    if started {
      // URLSession inherits task cancellation. Cleanup needs a fresh task so
      // hiding the tab can still deliver the authenticated stop request.
      let stop = request(.stop, viewerId: viewerId)
      let client = client
      await Task { _ = try? await client.screenSharing(stop) }.value
    }
  }

  private func attempt(
    viewerId: UUID, display: String, restarts: Int, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void
  ) async -> (Outcome, started: Bool) {
    let attempt = Attempt()
    let body = Task { @MainActor [self] () -> Outcome in
      do {
        // Fetch fresh short-lived relay credentials at connection time. The
        // display picker may have been left open much longer than their lifetime.
        let capabilities = try await client.screenSharing(request(.capabilities, viewerId: viewerId))
        try Task.checkCancellation()
        guard capabilities.version == 1, ["available", "busy"].contains(capabilities.status) else {
          return .ended(capabilities.message ?? "Screen Sharing is unavailable on this Mac.")
        }
        let session = try makeSession(capabilities.connectivity)
        let endpoint = ScreenSharingViewerEndpoint(session: session, surface: try makeSurface(session))
        attempt.endpoint = endpoint
        endpoint.onReady = {
          attempt.ready = true; emit(.ready)
        }
        endpoint.control.onReleased = { emit(.controlReleased) }
        session.onConnectionChanged = { transport in
          guard ["failed", "disconnected", "closed"].contains(transport), attempt.outcome == nil else { return }
          attempt.outcome =
            attempt.ready && restarts < 3 && transport != "closed"
            ? .lost : .ended("The screen-sharing connection ended. Reconnect to continue.")
          attempt.body?.cancel()
        }
        emit(.opened(endpoint))
        let offer = try await session.offer()
        try Task.checkCancellation()
        attempt.started = true
        let reply = try await client.screenSharing(
          request(restarts == 0 ? .start : .restart, viewerId: viewerId, displayId: display, offer: offer))
        try Task.checkCancellation()
        guard reply.version == 1, reply.status == "connecting", let answer = reply.answer else {
          return .ended(reply.message ?? "This Mac cannot start screen sharing right now.")
        }
        try await session.accept(answer)
        var heartbeatsBeforeVideo = 0
        while true {
          try await sleep(.seconds(8))
          try Task.checkCancellation()
          let reply = try await client.screenSharing(request(.heartbeat, viewerId: viewerId))
          try Task.checkCancellation()
          guard reply.version == 1, ["connecting", "viewing"].contains(reply.status) else {
            return .ended(reply.message ?? "Screen sharing ended on the host Mac.")
          }
          if let failure = session.failure { return .ended(failure) }
          if !attempt.ready {
            heartbeatsBeforeVideo += 1
            guard heartbeatsBeforeVideo < 3 else {
              return .ended(
                "No video arrived. Check the connection between these Macs or the configured relay, then retry.")
            }
          }
        }
      } catch {
        return isTaskCancellation(error) ? .cancelled : .ended(serverErrorMessage(error))
      }
    }
    attempt.body = body
    let result = await withTaskCancellationHandler {
      await body.value
    } onCancel: {
      body.cancel()
    }
    // Teardown releases the lease; that is not a host revocation, so it is not reported.
    attempt.endpoint?.control.onReleased = nil
    attempt.endpoint?.close()
    // A transport outcome recorded by a callback wins over the cancellation it
    // caused; the stream's own cancellation wins over anything else.
    let outcome = Task.isCancelled ? .cancelled : (attempt.outcome ?? result)
    return (outcome, attempt.started)
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, viewerId: UUID, displayId: String? = nil, offer: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: workspaceId, paneId: paneId, viewerId: viewerId, displayId: displayId,
      offer: offer)
  }

  private struct ViewerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
