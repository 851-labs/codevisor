import CodevisorCore

public struct PluginAccountActions: Equatable, Sendable {
  public let spec: ServerPluginAccountSpec
  public let accounts: [ServerPluginAccount]

  public init(spec: ServerPluginAccountSpec, accounts: [ServerPluginAccount]) {
    self.spec = spec
    self.accounts = accounts
  }

  public var needsFirstAccount: Bool { accounts.isEmpty }

  public var addAnotherTitle: String { "Add \(spec.accountNoun)…" }

  public var removeTitle: String {
    spec.oauth == nil ? "Remove \(spec.accountNoun)" : "Sign Out"
  }

  public var rowRemoveTitle: String {
    spec.oauth == nil ? "Remove…" : "Sign Out…"
  }

  public func canRevisit(_ account: ServerPluginAccount) -> Bool {
    !account.isOAuth || account.needsReauthorization
  }

  public func revisitTitle(for account: ServerPluginAccount) -> String {
    account.isOAuth ? "Sign In Again…" : "Edit…"
  }

  public func name(of account: ServerPluginAccount) -> String {
    account.label ?? account.identity ?? spec.label
  }

  public func removalPrompt(for account: ServerPluginAccount) -> String {
    spec.oauth == nil ? "Remove \(name(of: account))?" : "Sign out of \(name(of: account))?"
  }
}
