import CodevisorTestSupport
import Foundation
import Testing
import CodevisorClient
@testable import CodevisorCloud

/// Session resume, app side: a reconnect offers the last welcome's resume
/// token so the hub keeps this device's session identity across the gap.
@Suite("CloudHubConnection resume")
struct CloudHubResumeTests {
  @Test("A reconnect offers the last welcome's resume token and keeps the session")
  func reconnectOffersResumeToken() async throws {
    let scripted = ScriptedCloudHub()
    scripted.issueResumeTokens = true
    let clock = TestClock()
    let hub = CloudHubConnection(
      serverURL: URL(string: "https://cloud.example.com")!,
      credentialStore: InMemoryCloudCredentialStore(token: "session-token"),
      deviceName: "Test App",
      deviceOS: "macOS",
      webSocketTransport: FakeWebSocketTransport { _ in scripted.makeSocket() },
      readyTimeout: .seconds(2),
      sleep: clock.sleep,
      reconnectDelay: { _ in .seconds(1) }
    )

    try await hub.waitUntilReady()
    let firstConnection = try #require(await hub.lastConnectionId)
    scripted.currentSocket.disconnect()

    await clock.waitForSleep(.seconds(1))
    #expect(await !hub.isWelcomed)
    clock.advance(by: .seconds(1))
    try await hub.waitUntilReady()

    #expect(scripted.helloResumeTokens.count == 2)
    #expect(scripted.helloResumeTokens.first == .some(nil))
    #expect(scripted.helloResumeTokens.last??.isEmpty == false)
    // The hub honoured the token: same session identity, no fresh start.
    #expect(await hub.lastConnectionId == firstConnection)
    await hub.shutdown()
  }
}
