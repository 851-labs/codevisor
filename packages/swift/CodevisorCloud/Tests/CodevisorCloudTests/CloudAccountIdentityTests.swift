import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Cloud account identity")
struct CloudAccountIdentityTests {
  @Test("Apple availability comes from server discovery")
  func appleDiscovery() async {
    let (controller, client, _) = makeController()
    #expect(!controller.supportsAppleSignIn)
    client.discoverResult = .success(CloudInstanceInfo(service: "codevisor-cloud", authProviders: ["apple"]))
    await controller.bootstrap()
    #expect(controller.supportsAppleSignIn)
    #expect(!controller.supportsGitHubSignIn)
    #expect(
      controller.signInURL(scheme: "codevisor", provider: .apple).absoluteString
        == "https://cloud.codevisor.dev/login/apple?redirect=/auth/handoff%3Fapp%3Dcodevisor")
    #expect(
      controller.signInURL(scheme: "codevisor-dev", provider: .apple).absoluteString
        == "https://cloud.codevisor.dev/login/apple?redirect=/auth/handoff%3Fapp%3Dcodevisor-dev")
  }

  @Test("Management handoff uses a single-use token in the fragment")
  func managementURL() async throws {
    let (controller, client, _) = await makeSignedIn(machines: [])
    let url = try #require(await controller.accountManagementURL(scheme: "codevisor-dev"))
    #expect(url.path == "/account")
    #expect(url.query() == "app=codevisor-dev")
    #expect(url.fragment() == "ott=management-ott")
    #expect(client.managementTokens == ["t"])
  }

  @Test("Failed deletion preserves the session and a successful retry clears it")
  func deleteAccount() async throws {
    let (controller, client, store) = await makeSignedIn(machines: [testMachine("mac")])
    client.deleteError = CloudAccountClientError.recentSignInRequired
    await controller.deleteAccount()
    #expect(controller.state.isSignedIn)
    #expect(try store.token() == "t")
    #expect(controller.lastError == CloudAccountClientError.recentSignInRequired.localizedDescription)
    client.deleteError = nil
    await controller.deleteAccount()
    #expect(controller.state == .signedOut)
    #expect(controller.machines.isEmpty)
    #expect(try store.token() == nil)
    #expect(client.deletionTokens == ["t", "t"])
  }
}
