import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCloud

@MainActor
@Suite("Cloud credential cache")
struct CloudCredentialCacheTests {
  @Test("Launch reads the stored server off the main thread; renders and switches never reread it")
  func credentialsAreReadOnceOffMain() async throws {
    let custom = URL(string: "https://cloud.example.com")!
    let store = CountingCredentialStore(base: InMemoryCloudCredentialStore(serverURL: custom))
    let client = FakeCloudClient()
    let controller = CloudAccountController(
      clientFactory: { _ in client }, credentialStore: store, environmentCloud: nil,
      directPaths: CloudDirectPathController(credentialStore: store, prober: { _, _ in nil }),
      presenceSleep: TestClock().sleep
    )
    await controller.bootstrap()
    #expect(store.credentialReadCounts == (token: 1, serverURL: 1, onMainThread: 0))

    for _ in 0..<50 {
      #expect(controller.serverURL == custom)
      #expect(controller.customServerURL == custom)
    }
    try await controller.setCustomServer(nil)
    #expect(controller.customServerURL == nil)
    #expect(controller.serverURL == CloudAccountController.defaultServerURL)
    #expect(try store.serverURL() == nil)
    #expect(store.credentialReadCounts.token == 1)
    #expect(store.credentialReadCounts.onMainThread == 1)
  }
}
