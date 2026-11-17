import Foundation

public struct PluginSignInHandoff: Equatable, Sendable {
  public let ticket: String
  public let url: URL

  public init?(serverURL: URL, pluginName: String?, ticket: String = UUID().uuidString) {
    guard Self.opensInThisBrowser(serverURL),
      var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
    else { return nil }

    components.path = "/v1/sign-in/\(ticket)"
    components.queryItems =
      [URLQueryItem(name: "app", value: CodevisorDeeplinkScheme.current)]
      + (pluginName.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
    guard let url = components.url else { return nil }

    self.ticket = ticket
    self.url = url
  }

  private static func opensInThisBrowser(_ serverURL: URL) -> Bool {
    guard serverURL.scheme == "http", let host = serverURL.host() else { return false }
    return host == "127.0.0.1" || host == "localhost"
  }
}
