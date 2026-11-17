import Foundation

extension CodevisorServerClienting {
  public func installCatalogPlugin(
    id: String,
    values: [String: ServerConfigFieldValue]
  ) async throws -> ServerMcpServer {
    try await installCatalogPlugin(id: id, values: values, authType: nil)
  }

  public func pluginCatalogSignIn(id: String) async throws -> ServerPluginCatalogSignIn {
    throw CodevisorServerClientError.invalidResponse
  }

  public func signInHandoff(pluginName: String?) -> PluginSignInHandoff? { nil }

  public func abandonSignIn(ticket: String) async throws {}

  public func startMcpOAuth(id: String) async throws -> ServerMcpOAuthStart {
    try await startMcpOAuth(id: id, ticket: nil)
  }

  public func installCatalogPlugin(
    id: String,
    values: [String: ServerConfigFieldValue],
    authType: String?
  ) async throws -> ServerMcpServer {
    throw CodevisorServerClientError.invalidResponse
  }

  public func startPluginAccountOAuth(
    serverId: String,
    request: ServerPluginAccountOAuthRequest,
    ticket: String?
  ) async throws -> ServerPluginAccountOAuthStart {
    throw CodevisorServerClientError.invalidResponse
  }
}
