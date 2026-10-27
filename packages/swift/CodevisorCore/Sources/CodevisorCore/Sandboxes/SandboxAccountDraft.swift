import CodevisorClient
import Foundation

public struct SandboxAccountDraft: Equatable, Identifiable, Sendable {
  public var accountId: String?
  public var provider: ServerSandboxProviderInfo
  public var label: String
  public var fields: SandboxFieldDraft
  public var secretsSet: Set<String>

  public var id: String { accountId ?? "new-\(provider.id)" }
  public var isNew: Bool { accountId == nil }
  public var canSave: Bool { fields.isFilled(provider.accountFields, secretsSet: secretsSet) }

  public init(provider: ServerSandboxProviderInfo, account: ServerSandboxAccount? = nil) {
    accountId = account?.id
    self.provider = provider
    label = account?.label ?? ""
    fields = SandboxFieldDraft(fields: provider.accountFields, values: account?.values ?? [:])
    secretsSet = Set(account?.secretsSet ?? [])
  }

  public var request: ServerSandboxAccountRequest {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return ServerSandboxAccountRequest(
      provider: provider.id, label: trimmed.isEmpty ? nil : trimmed, values: fields.values(for: provider.accountFields))
  }
}
