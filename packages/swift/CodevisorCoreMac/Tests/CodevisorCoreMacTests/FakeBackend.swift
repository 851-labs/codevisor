import CodevisorClient
import CodevisorTestSupport
import ComposableArchitecture
import Foundation
@testable import CodevisorCoreMac

@MainActor
final class FakeBackend {
  var displays: [ServerScreenSharingDisplay]
  var discoveryFailure: String?
  var discoveryGate: TestSignal?
  private(set) var connections: [String] = []
  private(set) var switches: [String] = []
  let terminations = LockIsolated(0)
  let shareCalls = LockIsolated<[String]>([])
  private(set) var endpoints: [ScreenSharingViewerEndpoint] = []
  private var continuation: AsyncStream<ScreenSharingViewerEvent>.Continuation?
  private var isLive = false
  private var liveContinuation: AsyncStream<Void>.Continuation?

  init(displays: [ServerScreenSharingDisplay]) { self.displays = displays }

  var value: ScreenSharingViewerBackend {
    ScreenSharingViewerBackend(
      connect: { [self] display in await MainActor.run { connect(display) } },
      switchDisplay: { [self] display in
        await MainActor.run {
          switches.append(display)
          return connect(display)
        }
      },
      discover: { [self] in
        if let gate = await MainActor.run(body: { discoveryGate }) { await gate.cancellableWait() }
        return try await MainActor.run {
          if let failure = discoveryFailure { throw Failure(failure) }
          return displays
        }
      },
      claim: { [shareCalls] in shareCalls.withValue { $0.append("claim") } },
      setVisible: { [shareCalls] visible in shareCalls.withValue { $0.append(visible ? "visible" : "hidden") } },
      retire: { [shareCalls] in shareCalls.withValue { $0.append("retire") } },
      liveStreams: { [self] in
        await MainActor.run {
          let (stream, continuation) = AsyncStream<Void>.makeStream()
          liveContinuation = continuation
          if isLive { continuation.yield() }
          return stream
        }
      })
  }

  private func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent> {
    connections.append(display)
    let terminations = terminations
    return AsyncStream { continuation in
      self.continuation = continuation
      continuation.onTermination = { _ in terminations.withValue { $0 += 1 } }
    }
  }

  @discardableResult
  func open(display: String? = nil) -> ScreenSharingViewerEndpoint {
    let endpoint = ScreenSharingViewerEndpoint(
      session: FakeMediaSession(), surface: FakeSurface(), displayId: display)
    endpoints.append(endpoint)
    continuation?.yield(.opened(endpoint))
    return endpoint
  }

  func emit(_ event: ScreenSharingViewerEvent) { continuation?.yield(event) }
  func end() { continuation?.finish() }

  func streamElsewhere() {
    isLive = true
    liveContinuation?.yield()
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
