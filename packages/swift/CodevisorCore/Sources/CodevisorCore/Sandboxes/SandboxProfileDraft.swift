import CodevisorClient
import Foundation

public struct SandboxProfileDraft: Equatable, Identifiable, Sendable {
  public var profileId: String?
  public var provider: ServerSandboxProviderInfo
  public var name: String
  public var accountId: String?
  public var fields: SandboxFieldDraft

  public var id: String { profileId ?? "new-\(provider.id)" }
  public var isNew: Bool { profileId == nil }

  public var isFilled: Bool { !trimmedName.isEmpty && fields.isFilled(provider.profileFields) }

  public var canSave: Bool { isFilled && (!provider.usesAccounts || accountId != nil) }

  public init(provider: ServerSandboxProviderInfo, profile: ServerSandboxProfile? = nil, accountId: String? = nil) {
    profileId = profile?.id
    self.provider = provider
    name = profile?.name ?? "\(provider.sandboxNoun.prefix(1).uppercased())\(provider.sandboxNoun.dropFirst())"
    self.accountId = profile?.accountId ?? accountId
    fields = SandboxFieldDraft(fields: provider.profileFields, values: profile?.values ?? [:])
  }

  public var request: ServerSandboxProfileRequest {
    ServerSandboxProfileRequest(
      name: trimmedName, provider: provider.id, accountId: provider.usesAccounts ? accountId : nil,
      values: fields.values(for: provider.profileFields))
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}
