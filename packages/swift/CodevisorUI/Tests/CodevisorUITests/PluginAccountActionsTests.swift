import CodevisorCore
import Testing

@testable import CodevisorUI

struct PluginAccountActionsTests {
  private let google = ServerPluginAccountSpec(
    label: "Google account", oauth: ServerPluginOAuthSpec(provider: "google"))
  private let apiKey = ServerPluginAccountSpec(
    label: "Grafana", fields: [ServerConfigField(key: "url", label: "URL", type: .url, required: true)])

  private func account(
    _ id: String, label: String? = nil, identity: String? = nil, method: String = "oauth2", status: String = "ok"
  ) -> ServerPluginAccount {
    ServerPluginAccount(id: id, plugin: "gmail", label: label, identity: identity, method: method, status: status)
  }

  @Test("An account labeled with its own email shows the email once")
  func labelMatchingIdentity() {
    let same = PluginAccountLabel(
      account: account("a", label: "dylan@851.sh", identity: "Dylan@851.sh"), fallbackName: "Google account")
    let renamed = PluginAccountLabel(
      account: account("b", label: "Work", identity: "dylan@851.sh"), fallbackName: "Google account")

    #expect(same.title == "dylan@851.sh")
    #expect(same.subtitle == nil)
    #expect(renamed.title == "Work")
    #expect(renamed.subtitle == "dylan@851.sh")
  }

  @Test("Sign-in is the first action only while no account is connected")
  func firstAccount() {
    let empty = PluginAccountActions(spec: google, accounts: [])
    let connected = PluginAccountActions(spec: google, accounts: [account("a", identity: "dylan@851.sh")])

    #expect(empty.needsFirstAccount)
    #expect(!connected.needsFirstAccount)
    #expect(connected.addAnotherTitle == "Add Account…")
  }

  @Test("Offers Sign In Again only for a single account that needs it, and Edit for a single field account")
  func revisit() {
    let healthy = PluginAccountActions(spec: google, accounts: [account("a")])
    let expired = PluginAccountActions(spec: google, accounts: [account("a", status: "reauthorize")])
    let fields = PluginAccountActions(spec: apiKey, accounts: [account("k", method: "fields")])
    let several = PluginAccountActions(
      spec: google, accounts: [account("a", status: "reauthorize"), account("b")])

    #expect(healthy.revisitTarget == nil)
    #expect(expired.revisitTarget.map(expired.revisitTitle(for:)) == "Sign In Again…")
    #expect(fields.revisitTarget.map(fields.revisitTitle(for:)) == "Edit…")
    #expect(several.revisitTarget == nil)
  }

  @Test("Sign-out names the one account, or asks which when there are several")
  func removal() {
    let work = account("a", identity: "dylan@851.sh")
    let personal = account("b", label: "Personal", identity: "me@example.com")
    let actions = PluginAccountActions(spec: google, accounts: [work, personal])
    let fields = PluginAccountActions(spec: apiKey, accounts: [account("k", method: "fields")])

    #expect(actions.removalPrompt(for: [work]) == "Sign out of dylan@851.sh?")
    #expect(actions.removalButtonTitle(for: work, among: [work]) == "Sign Out")
    #expect(actions.removalPrompt(for: [work, personal]) == "Choose an account to sign out")
    #expect(actions.removalButtonTitle(for: personal, among: [work, personal]) == "Sign Out Personal")
    #expect(fields.removalPrompt(for: fields.accounts) == "Remove Grafana?")
    #expect(fields.removeTitle == "Remove Account")
  }
}
