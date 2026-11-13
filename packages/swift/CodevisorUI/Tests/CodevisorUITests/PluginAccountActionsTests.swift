import CodevisorCore
import Testing

@testable import CodevisorUI

struct PluginAccountActionsTests {
  private let google = ServerPluginAccountSpec(
    label: "Google account", oauth: ServerPluginOAuthSpec(provider: "google"))
  private let slack = ServerPluginAccountSpec(
    label: "Slack workspace", noun: "workspace",
    fields: [ServerConfigField(key: "userToken", label: "Token", type: .secret, required: true)])
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

  @Test("Sign-in is the first action only while no account is connected, and Add names the plugin's account noun")
  func firstAccount() {
    let empty = PluginAccountActions(spec: google, accounts: [])
    let connected = PluginAccountActions(spec: google, accounts: [account("a", identity: "dylan@851.sh")])
    let workspaces = PluginAccountActions(spec: slack, accounts: [account("w", method: "fields")])

    #expect(empty.needsFirstAccount)
    #expect(!connected.needsFirstAccount)
    #expect(connected.addAnotherTitle == "Add Account…")
    #expect(slack.accountsTitle == "Workspaces" && workspaces.addAnotherTitle == "Add Workspace…")
    #expect(workspaces.removeTitle == "Remove Workspace" && workspaces.rowRemoveTitle == "Remove…")
  }

  @Test("Each account offers Edit, or Sign In Again only once its sign-in has lapsed")
  func revisit() {
    let actions = PluginAccountActions(spec: google, accounts: [])
    let fields = PluginAccountActions(spec: apiKey, accounts: [])
    let expired = account("a", status: "reauthorize")
    let key = account("k", method: "fields")

    #expect(!actions.canRevisit(account("a")))
    #expect(actions.canRevisit(expired) && actions.revisitTitle(for: expired) == "Sign In Again…")
    #expect(fields.canRevisit(key) && fields.revisitTitle(for: key) == "Edit…")
  }

  @Test("Removing names the account, as a sign-out for OAuth plugins")
  func removal() {
    let work = account("a", identity: "dylan@851.sh")
    let actions = PluginAccountActions(spec: google, accounts: [work])
    let fields = PluginAccountActions(spec: apiKey, accounts: [account("k", method: "fields")])

    #expect(actions.removalPrompt(for: work) == "Sign out of dylan@851.sh?")
    #expect(actions.removeTitle == "Sign Out" && actions.rowRemoveTitle == "Sign Out…")
    #expect(fields.removalPrompt(for: account("k", method: "fields")) == "Remove Grafana?")
    #expect(fields.removeTitle == "Remove Account")
  }
}
