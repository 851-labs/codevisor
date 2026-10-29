import CodevisorCore

public struct PluginAccountActions: Equatable, Sendable {
  public let spec: ServerPluginAccountSpec
  public let accounts: [ServerPluginAccount]

  public init(spec: ServerPluginAccountSpec, accounts: [ServerPluginAccount]) {
    self.spec = spec
    self.accounts = accounts
  }

  public var needsFirstAccount: Bool { accounts.isEmpty }

  public var addAnotherTitle: String { "Add Account…" }

  public var removeTitle: String {
    spec.oauth == nil ? "Remove Account" : "Sign Out"
  }

  public var revisitTarget: ServerPluginAccount? {
    guard accounts.count == 1, let account = accounts.first else { return nil }
    guard !account.isOAuth || account.needsReauthorization else { return nil }
    return account
  }

  public func revisitTitle(for account: ServerPluginAccount) -> String {
    account.isOAuth ? "Sign In Again…" : "Edit…"
  }

  public func name(of account: ServerPluginAccount) -> String {
    account.label ?? account.identity ?? spec.label
  }

  public func removalPrompt(for candidates: [ServerPluginAccount]) -> String {
    guard candidates.count == 1, let account = candidates.first else {
      return "Choose an account to \(removeTitle.lowercased())"
    }
    return spec.oauth == nil ? "Remove \(name(of: account))?" : "Sign out of \(name(of: account))?"
  }

  public func removalButtonTitle(for account: ServerPluginAccount, among candidates: [ServerPluginAccount]) -> String {
    candidates.count == 1 ? removeTitle : "\(removeTitle) \(name(of: account))"
  }
}
