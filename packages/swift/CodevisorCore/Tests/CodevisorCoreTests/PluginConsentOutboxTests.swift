import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Plugin consent delivery")
struct PluginConsentOutboxTests {
  struct Offline: Error {}

  @Test("Offline consent persists and retries only for its original account session")
  func persistenceAndAccountIsolation() async throws {
    let store = InMemoryStore()
    let first = PluginConsentOutbox(store: store)
    let payload = Data("permission".utf8)
    let id = try first.record(key: "plugin", scope: "account-a", body: payload)
    try first.record(key: "local-plugin", scope: nil, body: Data("local".utf8))
    let offline = try await first.flush(scope: "account-a") { _ in throw Offline() }
    #expect(Array(offline.failures.keys) == [id])
    let restored = PluginConsentOutbox(store: store)
    var sent: [Data] = []
    _ = try await restored.flush(scope: "account-b") { sent.append($0) }
    _ = try await restored.flush(scope: nil) { sent.append($0) }
    #expect(sent.isEmpty)
    _ = try await restored.flush(scope: "account-a") { sent.append($0) }
    #expect(sent == [payload])
    _ = try await PluginConsentOutbox(store: store).flush(scope: "account-a") { sent.append($0) }
    #expect(sent == [payload])
  }

  @Test("Consent saved before it carried a publisher is repaired from the plugin id and resent")
  func repairsOldBodies() async throws {
    let outbox = PluginConsentOutbox(store: InMemoryStore())
    try outbox.record(
      key: "catalog", scope: "account", body: oldBody(pluginId: "io.github.Acme/notes", version: "1.2.0"))
    try outbox.record(key: "custom", scope: "account", body: oldBody(pluginId: "custom:mcp.example.com", version: ""))
    var sent: [String: [String: Any]] = [:]

    let outcome = try await outbox.flush(scope: "account") { body in
      let consent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
      sent[try #require(consent["pluginId"] as? String)] = consent["metadata"] as? [String: Any]
    }

    #expect(outcome.rejected.isEmpty && outcome.failures.isEmpty)
    #expect(sent["io.github.Acme/notes"]?["publisher"] as? String == "io.github.acme")
    #expect(sent["io.github.Acme/notes"]?["version"] as? String == "1.2.0")
    #expect(sent["custom:mcp.example.com"]?["publisher"] as? String == "mcp.example.com")
    #expect(sent["custom:mcp.example.com"]?["version"] as? String == "custom")
  }

  @Test("Consent the cloud still rejects after repair is dropped without blocking the rest")
  func dropsRejectedConsent() async throws {
    let store = InMemoryStore()
    let outbox = PluginConsentOutbox(store: store)
    let bad = try outbox.record(
      key: "bad", scope: "account", body: oldBody(pluginId: "custom:npx -y notes", version: ""))
    try outbox.record(key: "good", scope: "account", body: oldBody(pluginId: "acme/notes", version: "1"))
    var accepted: [String] = []
    let cloud: (Data) async throws -> Void = { body in
      let pluginId = try Self.pluginId(of: body)
      guard !pluginId.contains(" ") else { throw PluginConsentOutbox.Rejected() }
      accepted.append(pluginId)
    }

    let first = try await outbox.flush(scope: "account", send: cloud)
    let second = try await PluginConsentOutbox(store: store).flush(scope: "account", send: cloud)

    #expect(first.rejected == [bad])
    #expect(first.failures.isEmpty)
    #expect(accepted == ["acme/notes"])
    #expect(second.rejected.isEmpty)
  }

  @Test("One consent that can't be sent yet doesn't hold back the others")
  func failuresDoNotBlock() async throws {
    let outbox = PluginConsentOutbox(store: InMemoryStore())
    let stuck = try outbox.record(key: "stuck", scope: "account", body: oldBody(pluginId: "acme/stuck", version: "1"))
    try outbox.record(key: "next", scope: "account", body: oldBody(pluginId: "acme/next", version: "1"))
    var accepted: [String] = []

    let outcome = try await outbox.flush(scope: "account") { body in
      let pluginId = try Self.pluginId(of: body)
      guard pluginId != "acme/stuck" else { throw Offline() }
      accepted.append(pluginId)
    }
    let retry = try await outbox.flush(scope: "account") { accepted.append(try Self.pluginId(of: $0)) }

    #expect(Array(outcome.failures.keys) == [stuck])
    #expect(accepted == ["acme/next", "acme/stuck"])
    #expect(retry.failures.isEmpty)
  }

  private func oldBody(pluginId: String, version: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "pluginId": pluginId,
      "consentKey": String(repeating: "a", count: 64),
      "noticeVersion": 1,
      "metadata": ["name": "Notes", "version": version, "ageRating": 4, "panes": [], "tools": []],
    ])
  }

  private static func pluginId(of body: Data) throws -> String {
    let consent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(consent["pluginId"] as? String)
  }
}
