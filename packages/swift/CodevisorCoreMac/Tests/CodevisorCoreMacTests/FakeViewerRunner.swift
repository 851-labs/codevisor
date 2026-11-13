import CodevisorTestSupport
import Foundation
@testable import CodevisorCoreMac

@MainActor
final class FakeViewerRunner: ScreenSharingViewerConnecting {
  let connected = TestSignal()
  let terminated = TestSignal()
  let idling = TestSignal()
  let stopFinished = TestSignal()
  var holdsStop = false
  private(set) var displays: [String] = []
  private var continuation: AsyncStream<ScreenSharingViewerEvent>.Continuation?

  func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent> {
    displays.append(display)
    let (stream, continuation) = AsyncStream<ScreenSharingViewerEvent>.makeStream()
    self.continuation = continuation
    continuation.onTermination = { [terminated] _ in terminated.signal() }
    connected.signal()
    return stream
  }

  func idle() async {
    idling.signal()
    if holdsStop { await stopFinished.wait() }
  }

  func send(_ event: ScreenSharingViewerEvent) { continuation?.yield(event) }
  func finish() { continuation?.finish() }
}
