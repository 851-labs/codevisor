import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("Plugin consent delivery")
struct PluginConsentOutboxTests {
  @Test("Offline consent persists and retries only for its original account session")
  func persistenceAndAccountIsolation() async throws {
    let store = InMemoryStore()
    let first = PluginConsentOutbox(store: store)
    let payload = Data("permission".utf8)
    try first.record(key: "plugin", scope: "account-a", body: payload)
    try first.record(key: "local-plugin", scope: nil, body: Data("local".utf8))
    struct Offline: Error {}
    await #expect(throws: Offline.self) {
      try await first.flush(scope: "account-a") { _ in throw Offline() }
    }
    let restored = PluginConsentOutbox(store: store)
    var sent: [Data] = []
    try await restored.flush(scope: "account-b") { sent.append($0) }
    try await restored.flush(scope: nil) { sent.append($0) }
    #expect(sent.isEmpty)
    try await restored.flush(scope: "account-a") { sent.append($0) }
    #expect(sent == [payload])
    try await PluginConsentOutbox(store: store).flush(scope: "account-a") { sent.append($0) }
    #expect(sent == [payload])
  }
}
