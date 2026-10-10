import Foundation

/// Artwork for a transcript tool-call icon, resolved and cached by the
/// server: a site's favicon, or an MCP server's own icon.
public enum ServerToolIconRequest: Hashable, Sendable {
  case site(origin: String, dark: Bool)
  /// `host` lets the server fall back to the brand's favicon for a server
  /// it doesn't have (removed, or on another machine).
  case mcpServer(id: String, host: String?, dark: Bool)

  var path: String {
    let path: String
    var query = URLComponents()
    switch self {
    case let .site(origin, dark):
      path = "/v1/tool-icons/site"
      query.queryItems = [URLQueryItem(name: "origin", value: origin), Self.theme(dark)]
    case let .mcpServer(id, host, dark):
      path = "/v1/tool-icons/mcp/\(id.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? id)"
      query.queryItems = [host.map { URLQueryItem(name: "host", value: $0) }, Self.theme(dark)].compactMap { $0 }
    }
    return query.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
  }

  private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

  private static func theme(_ dark: Bool) -> URLQueryItem {
    URLQueryItem(name: "theme", value: dark ? "dark" : "light")
  }
}

extension CodevisorServerClient {
  public func toolIcon(_ request: ServerToolIconRequest) async throws -> Data {
    try await performRaw(request.path, method: "GET", body: nil, contentType: nil)
  }
}
