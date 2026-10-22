import Foundation

enum CloudAuthLinks {
  static func signIn(server: URL, scheme: String, provider: CloudSignInProvider) -> URL {
    let base = withoutTrailingSlash(server.absoluteString)
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "?=&+")
    let redirect = "/auth/handoff?app=\(scheme)"
    let encoded = redirect.addingPercentEncoding(withAllowedCharacters: allowed) ?? redirect
    return URL(string: "\(base)/login/\(provider.rawValue)?redirect=\(encoded)") ?? server
  }

  static func connectAccount(server: URL, provider: CloudSignInProvider, scheme: String, ott: String) -> URL? {
    var url = URLComponents(
      url: server.appendingPathComponent("auth/connect/\(provider.rawValue)"), resolvingAgainstBaseURL: false)!
    url.queryItems = [URLQueryItem(name: "app", value: scheme)]
    var fragment = URLComponents()
    fragment.queryItems = [URLQueryItem(name: "ott", value: ott)]
    url.percentEncodedFragment = fragment.percentEncodedQuery
    return url.url
  }

  private static func withoutTrailingSlash(_ text: String) -> String {
    guard text.hasSuffix("/") else { return text }
    return String(text.dropLast())
  }
}
