import CodevisorCore
import Foundation

public struct PluginAccountEditing: Identifiable, Equatable {
  public let accountId: String?
  public let oauthProvider: String?
  public var label: String
  public var draft: ConfigFieldDraft

  public init(newAccountFor spec: ServerPluginAccountSpec) {
    accountId = nil
    oauthProvider = spec.providerName
    label = ""
    draft = ConfigFieldDraft(fields: spec.fields)
  }

  public init(account: ServerPluginAccount, spec: ServerPluginAccountSpec) {
    accountId = account.id
    oauthProvider = account.isOAuth ? spec.providerName : nil
    label = account.label ?? ""
    draft = ConfigFieldDraft(fields: spec.fields, values: account.values, secretsSet: account.secretsSet)
  }

  public var id: String { accountId ?? "new" }

  public var title: String {
    accountId == nil ? "Add Account" : "Edit Account"
  }

  public var submitTitle: String {
    if let oauthProvider { return "Sign in with \(oauthProvider)" }
    return accountId == nil ? "Add" : "Save"
  }

  public var namesAccount: Bool { oauthProvider == nil }

  public var canSubmit: Bool { draft.isComplete }

  public var trimmedLabel: String? {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
