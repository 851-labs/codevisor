import Foundation
import Observation

@MainActor
@Observable
public final class PluginAccessController {
  private let cloud: CloudAccountController
  private let consentOutbox: PluginConsentOutbox
  public let catalog: PluginCatalogClient
  private var currentPolicy: PluginAccessPolicy?
  public private(set) var revision = 0
  public private(set) var blockedPublishers: [String] = []

  public init(
    cloud: CloudAccountController, store: any PersistenceStore = InMemoryStore(),
    catalog: PluginCatalogClient = PluginCatalogClient()
  ) {
    self.cloud = cloud
    self.catalog = catalog
    self.consentOutbox = PluginConsentOutbox(store: store)
  }

  public func snapshot() async throws -> (PluginAccessPolicy, PluginPreferences) {
    try? await syncConsent()
    async let policyRequest = refreshPolicy()
    async let preferencesData = cloud.pluginRequest(path: "/api/plugins/preferences")
    let policy = try await policyRequest
    let preferences = try await JSONDecoder().decode(PluginPreferences.self, from: preferencesData)
    blockedPublishers = preferences.blockedPublishers.sorted()
    return (policy, preferences)
  }

  @discardableResult
  public func refreshPolicy() async throws -> PluginAccessPolicy {
    let policy = try await catalog.policy()
    currentPolicy = policy
    return policy
  }

  public func review(_ plugin: ServerPluginRemoteDiscovery) async throws -> Bool {
    let (policy, preferences) = try await snapshot()
    if let reason = policy.restriction(
      pluginId: plugin.id, ageRating: plugin.ageRating, blockedPublishers: preferences.blockedPublishers)
    {
      throw PluginAccessError(reason)
    }
    let registry = try await catalog.index()
    return registry.entries.contains { $0.id == plugin.id && $0.repo.lowercased() == plugin.sourceRepo?.lowercased() }
  }

  public func ageRating(pluginId: String, declared: Int?) -> Int? {
    currentPolicy?.ageRating(pluginId: pluginId, declared: declared) ?? declared
  }

  public func requireAccess(to plugin: ServerPluginSummary) async throws {
    try await requireEligible(pluginId: plugin.id, ageRating: plugin.ageRating)
  }

  public func requireEligible(pluginId: String, ageRating: Int?) async throws {
    let (policy, preferences) = try await snapshot()
    if let reason = policy.restriction(
      pluginId: pluginId, ageRating: ageRating, blockedPublishers: preferences.blockedPublishers)
    {
      throw PluginAccessError(reason)
    }
  }

  public func recordConsent(pluginId: String, consentKey: String?, metadata: PluginConsentMetadata) async throws {
    guard let consentKey else { throw PluginAccessError("Update the connected machine to install this plugin.") }
    struct Consent: Encodable {
      let pluginId: String; let consentKey: String; let metadata: PluginConsentMetadata; let noticeVersion = 1
    }
    let body = try JSONEncoder().encode(Consent(pluginId: pluginId, consentKey: consentKey, metadata: metadata))
    try consentOutbox.record(key: "\(pluginId):\(consentKey)", scope: cloud.pluginConsentScope, body: body)
    #if os(macOS)
      // A cloud outage or a signed-out account must not prevent Mac installation.
      try? await syncConsent()
    #else
      guard cloud.pluginConsentScope != nil else { throw PluginAccessError("Sign in to install plugins.") }
      try await syncConsent()
    #endif
    revision += 1
  }

  public func syncConsent() async throws {
    try await consentOutbox.flush(scope: cloud.pluginConsentScope) { [cloud] body in
      _ = try await cloud.pluginRequest(path: "/api/plugins/consent", method: "POST", body: body)
    }
  }

  public func report(id: UUID, pluginId: String, name: String, reason: String, details: String) async throws {
    let body = try JSONEncoder().encode([
      "id": id.uuidString, "pluginId": pluginId, "pluginName": name, "reason": reason, "details": details,
    ])
    _ = try await cloud.pluginRequest(path: "/api/plugins/reports", method: "POST", body: body)
  }

  public func setPublisherBlocked(_ publisher: String, blocked: Bool) async throws {
    guard !publisher.isEmpty, publisher.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
      throw PluginAccessError("This publisher could not be identified.")
    }
    _ = try await cloud.pluginRequest(path: "/api/plugins/publishers/\(publisher)", method: blocked ? "PUT" : "DELETE")
    if blocked { blockedPublishers.append(publisher) } else { blockedPublishers.removeAll { $0 == publisher } }
    revision += 1
  }
}
