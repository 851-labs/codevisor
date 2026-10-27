import Foundation

public struct ServerSandboxProviders: Decodable, Equatable, Sendable {
  public var providers: [ServerSandboxProviderInfo]
  public var capabilities: [String]

  public init(providers: [ServerSandboxProviderInfo] = [], capabilities: [String] = []) {
    self.providers = providers
    self.capabilities = capabilities
  }

  public func provider(_ id: String) -> ServerSandboxProviderInfo? {
    providers.first { $0.id == id }
  }
}
