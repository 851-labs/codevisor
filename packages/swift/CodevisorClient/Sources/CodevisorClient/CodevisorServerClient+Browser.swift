import Foundation

public struct ServerBrowserProxySession: Codable, Sendable, Equatable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

extension CodevisorServerClient {
  public func browserProxySession() async throws -> ServerBrowserProxySession {
    try await send(
      "/v1/browser/proxy-session", method: "POST", body: Optional<EmptyBody>.none
    )
  }
}

extension CodevisorServerClient {
  public func browserProxyFailure(authority: String) async throws -> String? {
    var components = URLComponents()
    components.queryItems = [URLQueryItem(name: "authority", value: authority)]
    let result: ProxyFailureResponse = try await get(
      "/v1/browser/proxy-failure?\(components.percentEncodedQuery ?? "")")
    return result.failure
  }
}

public extension CodevisorServerClienting {
  func browserProxySession() async throws -> ServerBrowserProxySession {
    throw URLError(.unsupportedURL)
  }
  func browserProxyFailure(authority: String) async throws -> String? { throw URLError(.unsupportedURL) }
}

private struct ProxyFailureResponse: Decodable { var failure: String? }

private struct CookieExchange: Encodable { var mutations: [BrowserCookieMutation] }
private struct NavigationResponse: Decodable { var navigation: BrowserNavigation? }
private struct FaviconUpload: Encodable { var data: Data }
private struct FaviconResponse: Decodable { var favicon: Data? }

extension CodevisorServerClient {
  public func exchangeBrowserCookies(_ mutations: [BrowserCookieMutation]) async throws -> BrowserCookieSnapshot {
    try await send("/v1/browser/state/cookies", method: "POST", body: CookieExchange(mutations: mutations))
  }
  public func browserNavigation(paneId: UUID) async throws -> BrowserNavigation? {
    let result: NavigationResponse = try await get("/v1/browser/state/panes/\(paneId.uuidString.lowercased())")
    return result.navigation
  }
  public func publishBrowserNavigation(paneId: UUID, navigation: BrowserNavigation) async throws {
    let _: EmptyResponse = try await send(
      "/v1/browser/state/panes/\(paneId.uuidString.lowercased())", method: "PUT", body: navigation)
  }
  public func browserFavicon(sha256: String) async throws -> Data? {
    let result: FaviconResponse = try await get("/v1/browser/state/favicons/\(sha256)")
    return result.favicon
  }
  public func publishBrowserFavicon(sha256: String, png: Data) async throws {
    let _: EmptyResponse = try await send(
      "/v1/browser/state/favicons/\(sha256)", method: "PUT", body: FaviconUpload(data: png))
  }
}
private struct EmptyResponse: Decodable {}
public extension CodevisorServerClienting {
  func exchangeBrowserCookies(_ mutations: [BrowserCookieMutation]) async throws -> BrowserCookieSnapshot {
    throw URLError(.unsupportedURL)
  }
  func browserNavigation(paneId: UUID) async throws -> BrowserNavigation? { throw URLError(.unsupportedURL) }
  func publishBrowserNavigation(paneId: UUID, navigation: BrowserNavigation) async throws {
    throw URLError(.unsupportedURL)
  }
  func browserFavicon(sha256: String) async throws -> Data? { throw URLError(.unsupportedURL) }
  func publishBrowserFavicon(sha256: String, png: Data) async throws { throw URLError(.unsupportedURL) }
}
