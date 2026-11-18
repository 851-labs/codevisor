import CodevisorClient
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCloud

@MainActor
@Suite("Cloud credential cache")
struct CloudCredentialCacheTests {
  @Test("Launch reads the stored credentials off the main thread, once")
  func credentialsAreReadOnceOffMain() async throws {
    let store = CountingCredentialStore(base: InMemoryCloudCredentialStore())
    let client = FakeCloudClient()
    let controller = CloudAccountController(
      clientFactory: { _ in client }, credentialStore: store, environmentCloud: nil,
      directPaths: CloudDirectPathController(credentialStore: store, prober: { _, _ in nil }),
      presenceSleep: TestClock().sleep
    )
    await controller.bootstrap()
    #expect(store.credentialReadCounts == (token: 1, legacyServerURL: 1, onMainThread: 0))
  }

  @Test("A custom server saved by an older build signs out of it on launch and falls back to the default server")
  func retiredCustomServerFallsBackToDefault() async throws {
    let legacyServer = URL(string: "https://cloud.example.com")!
    let legacyClient = FakeCloudClient()
    let defaultClient = FakeCloudClient()
    let store = InMemoryCloudCredentialStore(token: "legacy-token", legacyServerURL: legacyServer)
    try store.savePinnedMachineKeys(["m1": "pk_m1"])
    let localServer = FakeLocalServerClient(
      registration: ServerCloudRegistration(
        connected: true, deviceId: "local-device-1", state: "connected", managedBy: "app"))
    let controller = CloudAccountController(
      clientFactory: { $0 == legacyServer ? legacyClient : defaultClient },
      credentialStore: store, environmentCloud: nil,
      directPaths: CloudDirectPathController(credentialStore: store, prober: { _, _ in nil }),
      presenceSleep: TestClock().sleep
    )
    controller.localServerClient = localServer

    await controller.bootstrap()
    await controller.localRegistration.deregistrationTask?.value

    #expect(controller.serverURL == CloudAccountController.defaultServerURL)
    #expect(controller.state == .signedOut)
    #expect(try store.token() == nil)
    #expect(try store.legacyServerURL() == nil)
    #expect(try store.pinnedMachineKeys().isEmpty)
    #expect(localServer.disconnects == 1)
    #expect(legacyClient.removals == ["local-device-1"])
    #expect(defaultClient.sessionTokens.isEmpty)
  }
}
