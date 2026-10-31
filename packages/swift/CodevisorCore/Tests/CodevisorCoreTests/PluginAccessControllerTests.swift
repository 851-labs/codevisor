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

  @Test("An iOS install records consent the cloud accepts, past an older consent it never will")
  func consentReachesTheCloud() async throws {
    let consents = ConsentLog()
    let cloud = CloudAccountController(
      clientFactory: { _ in PolicyCloudClient(consents: consents) },
      credentialStore: InMemoryCloudCredentialStore(token: "token", serverURL: URL(string: "https://cloud.test")))
    let store = InMemoryStore()
    try PluginConsentOutbox(store: store).record(
      key: "old", account: cloud.pluginConsentAccount, body: Data(#"{"pluginId":"custom:npx -y notes"}"#.utf8))
    let access = PluginAccessController(cloud: cloud, store: store, enforcesAgeGate: true)
    let notion = ServerPluginCatalogEntry(
      id: "com.notion/mcp", name: "Notion", description: "", publisher: "Notion", version: "remote", transport: "http")

    try await access.recordConsent(
      PluginModerationSubject(catalogEntry: notion), metadata: PluginConsentMetadata(notion, ageRating: 4))
    try await access.syncConsent()

    #expect(consents.accepted == ["com.notion/mcp by com.notion"])
  }

  @Test("Consent given while signed out goes to the next account, even after it signs out and back in")
  func signedOutConsentFollowsTheNextAccount() async throws {
    let consents = ConsentLog()
    let cloud = CloudAccountController(
      clientFactory: { _ in PolicyCloudClient(consents: consents) },
      credentialStore: InMemoryCloudCredentialStore(serverURL: URL(string: "https://cloud.test")))
    let access = PluginAccessController(cloud: cloud, store: InMemoryStore(), enforcesAgeGate: false)
    let notion = ServerPluginCatalogEntry(
      id: "com.notion/mcp", name: "Notion", description: "", publisher: "Notion", version: "remote", transport: "http")

    try await access.recordConsent(
      PluginModerationSubject(catalogEntry: notion), metadata: PluginConsentMetadata(notion, ageRating: 4))
    consents.isOffline = true
    await cloud.completeSignIn(ott: "user-a")
    await #expect(throws: (any Error).self) { try await access.syncConsent() }
    consents.isOffline = false
    cloud.signOut()
    await cloud.completeSignIn(ott: "user-b")
    try await access.syncConsent()
    #expect(consents.accepted.isEmpty)

    cloud.signOut()
    await cloud.completeSignIn(ott: "user-a")
    try await access.syncConsent()

    #expect(consents.accepted == ["com.notion/mcp by com.notion"])
  }
}

private final class ConsentLog: @unchecked Sendable {
  struct Offline: Error {}

  private let lock = NSLock()
  private var acceptedConsents: [String] = []
  private var offline = false

  var accepted: [String] { lock.withLock { acceptedConsents } }

  var isOffline: Bool {
    get { lock.withLock { offline } }
    set { lock.withLock { offline = newValue } }
  }

  func accept(_ body: Data) throws -> Data {
    guard !isOffline else { throw Offline() }
    let consent = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let metadata = consent?["metadata"] as? [String: Any]
    guard let pluginId = consent?["pluginId"] as? String, !pluginId.contains(" "),
      let publisher = metadata?["publisher"] as? String, !publisher.isEmpty,
      let version = metadata?["version"] as? String, !version.isEmpty
    else { throw CloudAccountClientError.httpStatus(400) }

    lock.withLock { acceptedConsents.append("\(pluginId) by \(publisher)") }
    return Data(#"{"ok":true}"#.utf8)
  }
}

private struct PolicyCloudClient: CloudAccountClienting {
  struct Unsupported: Error {}
  var consents = ConsentLog()

  func pluginRequest(path: String, method: String, body: Data?, token: String?) async throws -> Data {
    if path == "/api/plugins/consent", let body { return try consents.accept(body) }
    guard path == "/plugins/policy" else { throw Unsupported() }
    return Data(#"{"supportedAgeRating":16,"blocks":[],"ageRatings":[]}"#.utf8)
  }

  func emailAuthentication(_ request: CloudEmailAuthRequest) async throws -> String? { throw Unsupported() }
  func discover() async throws -> CloudInstanceInfo { throw Unsupported() }
  func verifyOneTimeToken(_ ott: String) async throws -> String { "session-\(UUID().uuidString):\(ott)" }
  func generateOneTimeToken(token: String) async throws -> String { throw Unsupported() }
  func linkedProviders(token: String) async throws -> Set<CloudSignInProvider> { throw Unsupported() }
  func startAppleSignIn(link: Bool, token: String?) async throws -> CloudAppleChallenge { throw Unsupported() }
  func completeAppleSignIn(_ credential: CloudAppleCredential, token: String?) async throws -> String {
    throw Unsupported()
  }
  func deleteAccount(token: String) async throws { throw Unsupported() }
  func developmentLogin() async throws -> String { throw Unsupported() }
  func session(token: String) async throws -> CloudSessionUser? {
    CloudSessionUser(userId: String(token.split(separator: ":").last ?? ""))
  }
  func machines(token: String) async throws -> [CloudMachine] { [] }
  func updateMachine(deviceId: String, name: String, icon: String?, token: String) async throws { throw Unsupported() }
  func removeMachine(deviceId: String, token: String) async throws { throw Unsupported() }
  func approveDevice(userCode: String, token: String) async throws { throw Unsupported() }
  func denyDevice(userCode: String, token: String) async throws { throw Unsupported() }
}
