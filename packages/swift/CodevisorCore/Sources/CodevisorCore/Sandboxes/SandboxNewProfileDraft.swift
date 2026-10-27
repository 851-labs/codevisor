import CodevisorClient
import Foundation

public struct SandboxNewProfileDraft: Equatable, Sendable {
  public enum Creation: Equatable, Sendable {
    case created
    case failed(SandboxNewProfileDraft)
  }

  public var account: SandboxAccountDraft?
  public var profile: SandboxProfileDraft

  public init(choice: SandboxSetupChoice) {
    account = choice.signsIn ? SandboxAccountDraft(provider: choice.provider) : nil
    profile = SandboxProfileDraft(provider: choice.provider, accountId: choice.account?.id)
  }

  public var provider: ServerSandboxProviderInfo { profile.provider }

  public var canSave: Bool {
    guard let account else { return profile.canSave }
    return account.canSave && profile.isFilled
  }
}
