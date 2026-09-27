import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@Suite("Relay socket cancellation")
struct CloudRelayCancellationTests {
  @Test("Cancelling a socket releases a receive still waiting for the pipe's welcome")
  func cancelBeforeWelcome() async {
    let clock = TestClock()
    let scripted = ScriptedDirectMachine()
    scripted.acceptsHello = false
    let (endpoint, pipe) = makeDirectEndpoint(to: scripted, readyTimeout: .seconds(20), clock: clock)
    let socket = CloudRelayWebSocketTransport(endpoint: endpoint).connect(
      URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/sessions/chat/events/socket")!),
      maximumMessageSize: 1024)
    let receive = Task { try await socket.receive() }
    await clock.waitForSleep(.seconds(20))
    socket.cancel(with: .goingAway, reason: nil)
    // No welcome, timeout advance, or upstream close is required to release it.
    switch await receive.result {
    case .success: Issue.record("Cancelled receive unexpectedly succeeded")
    case let .failure(error): #expect(error is CancellationError)
    }
    await pipe.shutdown()
  }
}
