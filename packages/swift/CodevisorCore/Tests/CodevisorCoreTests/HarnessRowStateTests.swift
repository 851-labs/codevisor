import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Harness list account summaries")
struct HarnessRowStateTests {
  @Test(
    "Only confirmed empty machine state offers direct sign-in",
    arguments: [
      "checking", "authenticated", "unauthenticated", "expired", "error", "unavailable", "notRequired", "future-state",
    ])
  func machineAuthentication(state: String) throws {
    let row = HarnessRowState.machine(try harness(state: state))
    #expect(row.needsSignIn == (state == "unauthenticated"))
    #expect(row.supportsAccounts == (state != "notRequired"))
    #expect(row.showsAccounts == !["unauthenticated", "notRequired"].contains(state))
  }

  @Test("An empty discovery slot offers sign-in instead of Accounts")
  func emptyDefaultAccount() throws {
    let row = HarnessRowState.machine(try harness(state: "unauthenticated", accounts: [account()]))
    #expect(row.needsSignIn)
    #expect(!row.showsAccounts)
  }

  @Test("Existing accounts remain manageable when signed out or expired", arguments: ["unauthenticated", "expired"])
  func existingAccounts(state: String) throws {
    var existing = account()
    existing["id"] = "managed-account"
    existing["profileKind"] = "managed"
    existing["authState"] = state
    let row = HarnessRowState.machine(try harness(state: state, accounts: [account(), existing]))
    #expect(!row.needsSignIn)
    #expect(row.showsAccounts)
    #expect(row.status == "Sign in required")
  }

  @Test("Signed-out shared accounts and saved OpenCode profiles keep Accounts")
  func savedSharedAccounts() async throws {
    let sync = AppEnvironment.preview().configSync
    await sync.synchronize(machineId: "local", namespaces: ["harness-shared-accounts", "harness-credentials"])
    sync.set(
      namespace: "harness-shared-accounts", key: "shared-person",
      value: .object([
        "id": .string("shared-person"), "harnessId": .string("claude-code"),
        "label": .string("Work"), "createdAt": .number(1),
      ]))
    let claude = HarnessRowState.shared(harnessId: "claude-code", sync: sync)
    #expect(claude.showsAccounts && !claude.needsSignIn)
    sync.remove(namespace: "harness-shared-accounts", key: "shared-person")
    #expect(!HarnessRowState.shared(harnessId: "claude-code", sync: sync).showsAccounts)

    sync.set(
      namespace: "harness-credentials", key: "profiles:opencode",
      value: .string(#"{"profiles":[{"id":"work","label":"Work"}],"activeProfileId":"default"}"#))
    let openCode = HarnessRowState.shared(harnessId: "opencode", sync: sync)
    #expect(openCode.showsAccounts && !openCode.needsSignIn)
    sync.remove(namespace: "harness-credentials", key: "profiles:opencode")
    #expect(!HarnessRowState.shared(harnessId: "opencode", sync: sync).showsAccounts)
  }

  @Test("Disabled harnesses keep Accounts but do not ask users to sign in")
  func disabled() throws {
    var harness = try harness(state: "unauthenticated")
    harness.desiredEnabled = false
    let row = HarnessRowState.machine(harness)
    #expect(!row.needsSignIn && row.supportsAccounts)
    #expect(row.status == nil)
  }

  @Test("Install and update progress takes precedence over sign-in")
  func lifecycle() throws {
    var harness = try harness(state: "unauthenticated")
    harness.lifecycle = .init(phase: "installing")
    #expect(HarnessRowState.machine(harness).isBusy)
    #expect(!HarnessRowState.machine(harness).needsSignIn)
    harness.lifecycle = nil
    harness.readiness = .init(state: "unavailable")
    #expect(!HarnessRowState.machine(harness).needsSignIn)
  }

  @Test("A fresh replica is unknown, then an acknowledged empty replica offers sign-in")
  func knownEmpty() async throws {
    let environment = AppEnvironment.preview()
    let sync = environment.configSync
    #expect(!HarnessRowState.shared(harnessId: "claude-code", sync: sync).needsSignIn)
    #expect(HarnessRowState.shared(harnessId: "claude-code", sync: sync).showsAccounts)
    await sync.synchronize(machineId: "local", namespaces: ["harness-shared-accounts", "harness-credentials"])
    #expect(HarnessRowState.shared(harnessId: "claude-code", sync: sync).needsSignIn)
    #expect(!HarnessRowState.shared(harnessId: "claude-code", sync: sync).showsAccounts)
    #expect(HarnessRowState.shared(harnessId: "codex", sync: sync).needsSignIn)
    #expect(!HarnessRowState.shared(harnessId: "cursor", sync: sync).needsSignIn)
    #expect(!HarnessRowState.shared(harnessId: "custom", sync: sync, authRequired: false).supportsAccounts)
  }

  @Test("Shared credentials decide global state, independently of a machine's signed-out override")
  func sharedOAuth() async throws {
    let sync = AppEnvironment.preview().configSync
    await sync.synchronize(machineId: "local", namespaces: ["harness-shared-accounts"])
    sync.set(namespace: "harness-shared-accounts", key: "selected:claude-code", value: .string("shared-person"))
    #expect(HarnessRowState.shared(harnessId: "claude-code", sync: sync).needsSignIn)
    sync.set(
      namespace: "harness-shared-accounts", key: "shared-person",
      value: .object([
        "harnessId": .string("claude-code"),
        "credential": .object(["id": .string("vault-id"), "key": .string("vault-key")]),
      ]))
    #expect(!HarnessRowState.shared(harnessId: "claude-code", sync: sync).needsSignIn)
    #expect(HarnessRowState.shared(harnessId: "claude-code", sync: sync).showsAccounts)
    #expect(HarnessRowState.machine(try harness(state: "unauthenticated")).needsSignIn)
    sync.remove(namespace: "harness-shared-accounts", key: "shared-person")
    #expect(HarnessRowState.shared(harnessId: "claude-code", sync: sync).needsSignIn)
    #expect(!HarnessRowState.shared(harnessId: "claude-code", sync: sync).showsAccounts)
  }

  @Test("An empty profile is not an account, but a profile with shared credentials is")
  func fileCredentials() async throws {
    let sync = AppEnvironment.preview().configSync
    await sync.synchronize(machineId: "local", namespaces: ["harness-shared-accounts", "harness-credentials"])
    sync.set(namespace: "harness-credentials", key: "opencode-profile:work", value: .string("{}"))
    #expect(HarnessRowState.shared(harnessId: "opencode", sync: sync).needsSignIn)
    sync.set(
      namespace: "harness-credentials", key: "opencode-profile:work",
      value: .string(#"{"openai":{"type":"api","key":"test-key"}}"#))
    #expect(!HarnessRowState.shared(harnessId: "opencode", sync: sync).needsSignIn)
    #expect(HarnessRowState.shared(harnessId: "pi", sync: sync).needsSignIn)
    sync.set(
      namespace: "harness-shared-accounts", key: "provider:pi:openai",
      value: .object([
        "harnessId": .string("pi"), "credential": .object(["id": .string("vault-id"), "key": .string("vault-key")]),
      ]))
    #expect(!HarnessRowState.shared(harnessId: "pi", sync: sync).needsSignIn)
  }

  private func account() -> [String: Any] {
    [
      "id": "default", "harnessId": "claude-code", "profileKind": "default", "label": "Existing Claude Code account",
      "authState": "unauthenticated", "isActive": true, "canLogin": true, "canLogout": false,
    ]
  }

  private func harness(state: String, accounts: [[String: Any]] = []) throws -> ServerHarness {
    let value: [String: Any] = [
      "id": "claude-code", "name": "Claude Code", "symbolName": "terminal", "source": "builtin",
      "launchKind": "executable", "enabled": false, "desiredEnabled": true, "readiness": ["state": "ready"],
      "auth": ["state": state, "accounts": accounts, "loginMethods": [], "supportsMultipleAccounts": true],
    ]
    return try JSONDecoder().decode(ServerHarness.self, from: JSONSerialization.data(withJSONObject: value))
  }
}
