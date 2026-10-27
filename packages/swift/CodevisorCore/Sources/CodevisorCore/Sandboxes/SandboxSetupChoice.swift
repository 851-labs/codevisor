import CodevisorClient
import Foundation

public struct SandboxSetupChoice: Equatable, Identifiable, Sendable {
  public let provider: ServerSandboxProviderInfo
  public let account: ServerSandboxAccount?

  public var id: String { account?.id ?? provider.id }
  public var signsIn: Bool { provider.usesAccounts && account == nil }

  public init(provider: ServerSandboxProviderInfo, account: ServerSandboxAccount? = nil) {
    self.provider = provider
    self.account = account
  }
}
