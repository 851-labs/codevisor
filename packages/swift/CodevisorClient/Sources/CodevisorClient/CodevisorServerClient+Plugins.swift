import Foundation

public struct ServerPluginPaneTokenRequest: Encodable, Equatable, Sendable {
  public var workspaceId: String?
  public var themeMode: String?

  public init(workspaceId: String? = nil, themeMode: String? = nil) {
    self.workspaceId = workspaceId
    self.themeMode = themeMode
  }
}

public struct ServerPluginPaneTokenResponse: Codable, Equatable, Sendable {
  public var url: String
  public var expiresAt: String

  public init(url: String, expiresAt: String) {
    self.url = url
    self.expiresAt = expiresAt
  }

  public func resolvedURL(base: URL) -> URL? {
    if let absolute = URL(string: url), absolute.scheme != nil { return absolute }
    let origin = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: origin + url)
  }
}

extension CodevisorServerClient {
  private struct PluginCatalogResponse: Decodable {
    var entries: [ServerPluginCatalogEntry]
  }

  private struct InstallCatalogPluginBody: Encodable {
    var values: [String: ServerConfigFieldValue]
  }

  private static let catalogIdAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

  public func listPluginCatalog(query: String?) async throws -> [ServerPluginCatalogEntry] {
    let response: PluginCatalogResponse = try await get(catalogPath(query: query))
    return response.entries
  }

  public func installCatalogPlugin(
    id: String,
    values: [String: ServerConfigFieldValue]
  ) async throws -> ServerMcpServer {
    try await send(
      "/v1/plugins/catalog/\(catalogPathComponent(id))/install",
      method: "POST",
      body: InstallCatalogPluginBody(values: values)
    )
  }

  public func issuePluginPaneToken(
    serverId: String,
    paneType: String,
    request: ServerPluginPaneTokenRequest
  ) async throws -> ServerPluginPaneTokenResponse {
    try await send(
      "/v1/plugins/\(pathComponent(serverId))/panes/\(pathComponent(paneType))/token",
      method: "POST",
      body: request
    )
  }

  func catalogPathComponent(_ id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: Self.catalogIdAllowed) ?? id
  }

  private func catalogPath(query: String?) -> String {
    let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return "/v1/plugins/catalog" }
    var components = URLComponents()
    components.path = "/v1/plugins/catalog"
    components.queryItems = [URLQueryItem(name: "query", value: trimmed)]
    return components.string ?? "/v1/plugins/catalog"
  }
}
