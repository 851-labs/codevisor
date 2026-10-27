import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Plugin access gate")
struct PluginAccessControllerTests {
  private let rated = PluginModerationSubject(
    pluginId: "acme/notes", name: "Notes", publisher: "acme", declaredAgeRating: 4, revision: "1")
  private let unrated = PluginModerationSubject(
    pluginId: "acme/raw", name: "Raw", publisher: "acme", declaredAgeRating: nil, revision: "1")

  private func controller(enforcing: Bool) -> PluginAccessController {
    let cloud = CloudAccountController(
      clientFactory: { _ in PolicyCloudClient() }, credentialStore: InMemoryCloudCredentialStore())
    return PluginAccessController(cloud: cloud, enforcesAgeGate: enforcing)
  }

  @Test("Without the age gate nothing is restricted")
  func ungated() async throws {
    let access = controller(enforcing: false)

    try await access.requireEligible(unrated)

    #expect(access.restriction(for: unrated) == nil)
  }

  @Test("With the age gate a plugin stays hidden until the policy is known, then follows it")
  func gated() async throws {
    let access = controller(enforcing: true)
    #expect(access.restriction(for: rated) != nil)

    try await access.refresh()

    #expect(access.restriction(for: rated) == nil)
    #expect(access.restriction(for: unrated) != nil)
    #expect(access.blockedPublishers.isEmpty)
    await #expect(throws: PluginAccessError.self) { try await access.requireEligible(unrated) }
  }
}

private struct PolicyCloudClient: CloudAccountClienting {
  struct Unsupported: Error {}

  func pluginRequest(path: String, method: String, body: Data?, token: String?) async throws -> Data {
    guard path == "/plugins/policy" else { throw Unsupported() }
    return Data(#"{"supportedAgeRating":16,"blocks":[],"ageRatings":[]}"#.utf8)
  }

  func emailAuthentication(_ request: CloudEmailAuthRequest) async throws -> String? { throw Unsupported() }
  func discover() async throws -> CloudInstanceInfo { throw Unsupported() }
  func verifyOneTimeToken(_ ott: String) async throws -> String { throw Unsupported() }
  func generateOneTimeToken(token: String) async throws -> String { throw Unsupported() }
  func linkedProviders(token: String) async throws -> Set<CloudSignInProvider> { throw Unsupported() }
  func startAppleSignIn(link: Bool, token: String?) async throws -> CloudAppleChallenge { throw Unsupported() }
  func completeAppleSignIn(_ credential: CloudAppleCredential, token: String?) async throws -> String {
    throw Unsupported()
  }
  func deleteAccount(token: String) async throws { throw Unsupported() }
  func developmentLogin() async throws -> String { throw Unsupported() }
  func session(token: String) async throws -> CloudSessionUser? { throw Unsupported() }
  func machines(token: String) async throws -> [CloudMachine] { throw Unsupported() }
  func updateMachine(deviceId: String, name: String, icon: String?, token: String) async throws { throw Unsupported() }
  func removeMachine(deviceId: String, token: String) async throws { throw Unsupported() }
  func approveDevice(userCode: String, token: String) async throws { throw Unsupported() }
  func denyDevice(userCode: String, token: String) async throws { throw Unsupported() }
}
