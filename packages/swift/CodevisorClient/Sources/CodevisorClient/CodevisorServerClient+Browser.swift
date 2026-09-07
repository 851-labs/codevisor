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

public extension CodevisorServerClienting {
  func browserProxySession() async throws -> ServerBrowserProxySession {
    throw URLError(.unsupportedURL)
  }
}

private struct CookieExchange: Encodable { var mutations: [BrowserCookieMutation] }
private struct NavigationResponse: Decodable { var navigation: BrowserNavigation? }

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
}
