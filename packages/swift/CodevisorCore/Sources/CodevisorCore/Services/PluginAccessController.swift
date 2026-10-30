import Foundation
import Observation

@MainActor
@Observable
public final class PluginAccessController {
  public static let enforcesAgeGateOnThisPlatform: Bool = {
    #if os(iOS)
      true
    #else
      false
    #endif
  }()

  public private(set) var revision = 0
  public private(set) var blockedPublishers: [String] = []
  public private(set) var policy: PluginAccessPolicy?

  @ObservationIgnored private let cloud: CloudAccountController
  @ObservationIgnored private let consentOutbox: PluginConsentOutbox
  @ObservationIgnored private let enforcesAgeGate: Bool

  public init(
    cloud: CloudAccountController,
    store: any PersistenceStore = InMemoryStore(),
    enforcesAgeGate: Bool = PluginAccessController.enforcesAgeGateOnThisPlatform
  ) {
    self.cloud = cloud
    self.consentOutbox = PluginConsentOutbox(store: store)
    self.enforcesAgeGate = enforcesAgeGate
  }

  public func restriction(for subject: PluginModerationSubject) -> String? {
    guard enforcesAgeGate else { return nil }
    guard let policy else { return "Codevisor is still checking whether this plugin can open on iOS." }

    return policy.restriction(for: subject, blockedPublishers: blockedPublishers)
  }

  public func restriction(for plugin: ServerMcpServer) -> String? {
    restriction(for: PluginModerationSubject(server: plugin))
  }

  public func isBlocked(publisher: String) -> Bool {
    blockedPublishers.contains(publisher)
  }

  public func ageRating(for subject: PluginModerationSubject) -> Int? {
    policy?.ageRating(pluginId: subject.pluginId, declared: subject.declaredAgeRating) ?? subject.declaredAgeRating
  }

  public func refresh() async throws {
    try? await syncConsent()
    let data = try await cloud.pluginRequest(path: "/plugins/policy")
    policy = try JSONDecoder().decode(PluginAccessPolicy.self, from: data)
    blockedPublishers = try await loadBlockedPublishers()
  }

  public func requireEligible(_ subject: PluginModerationSubject) async throws {
    guard enforcesAgeGate else { return }

    try await refresh()
    if let reason = restriction(for: subject) { throw PluginAccessError(reason) }
  }

  public func recordConsent(_ subject: PluginModerationSubject, metadata: PluginConsentMetadata) async throws {
    let body = try JSONEncoder().encode(
      PluginConsent(pluginId: subject.pluginId, consentKey: subject.consentKey, metadata: metadata))
    let id = try consentOutbox.record(
      key: "\(subject.pluginId):\(subject.consentKey)", scope: cloud.pluginConsentScope, body: body)
    try await deliverConsent(id, requiresAccount: enforcesAgeGate && !subject.isCustom)
  }

  public func syncConsent() async throws {
    try await flushConsent().throwFirstFailure()
  }

  public func report(id: UUID, subject: PluginModerationSubject, reason: String, details: String) async throws {
    let body = try JSONEncoder().encode([
      "id": id.uuidString, "pluginId": subject.pluginId, "pluginName": subject.name, "reason": reason,
      "details": details,
    ])
    _ = try await cloud.pluginRequest(path: "/api/plugins/reports", method: "POST", body: body)
  }

  public func setPublisherBlocked(_ publisher: String, blocked: Bool) async throws {
    guard Self.isValidPublisher(publisher) else { throw PluginAccessError("This publisher could not be identified.") }

    let path = "/api/plugins/publishers/\(publisher)"
    _ = try await cloud.pluginRequest(path: path, method: blocked ? "PUT" : "DELETE")
    if blocked { blockedPublishers.append(publisher) } else { blockedPublishers.removeAll { $0 == publisher } }
    blockedPublishers.sort()
    revision += 1
  }

  static func isValidPublisher(_ publisher: String) -> Bool {
    !publisher.isEmpty && publisher.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-.".contains($0)) }
  }

  private func loadBlockedPublishers() async throws -> [String] {
    guard cloud.pluginConsentScope != nil else { return [] }

    let data = try await cloud.pluginRequest(path: "/api/plugins/preferences")
    return try JSONDecoder().decode(PluginPreferences.self, from: data).blockedPublishers.sorted()
  }

  private func deliverConsent(_ id: String, requiresAccount: Bool) async throws {
    guard requiresAccount else {
      try? await syncConsent()
      return
    }
    guard cloud.pluginConsentScope != nil else { throw PluginAccessError("Sign in to install plugins.") }

    let outcome = try await flushConsent()
    if let failure = outcome.failures[id] { throw failure }
    guard !outcome.rejected.contains(id) else {
      throw PluginAccessError("Codevisor couldn't record your consent. Try again later.")
    }
  }

  private func flushConsent() async throws -> PluginConsentOutbox.Outcome {
    try await consentOutbox.flush(scope: cloud.pluginConsentScope) { [cloud] body in
      do {
        _ = try await cloud.pluginRequest(path: "/api/plugins/consent", method: "POST", body: body)
      } catch CloudAccountClientError.httpStatus(400) {
        throw PluginConsentOutbox.Rejected()
      }
    }
  }
}

private struct PluginConsent: Encodable {
  let pluginId: String
  let consentKey: String
  let metadata: PluginConsentMetadata
  let noticeVersion = 1
}
