import Foundation

public enum CloudSignInProvider: String, CaseIterable, Sendable {
  case github
  case apple
}

extension CloudAccountController {
  /// Starts browser OAuth with an app-specific, single-use session handoff.
  public func signInURL(scheme: String, provider: CloudSignInProvider = .github) -> URL {
    let base =
      serverURL.absoluteString.hasSuffix("/")
      ? String(serverURL.absoluteString.dropLast())
      : serverURL.absoluteString
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "?=&+")
    let redirect = "/auth/handoff?app=\(scheme)"
    let encoded = redirect.addingPercentEncoding(withAllowedCharacters: allowed) ?? redirect
    return URL(string: "\(base)/login/\(provider.rawValue)?redirect=\(encoded)") ?? serverURL
  }

  /// Establish the browser session from this app's account, even when the
  /// browser currently has another Cloud account signed in. The URL contains
  /// only a short-lived single-use token, never the stored session credential.
  public func connectAccountURL(provider: CloudSignInProvider, scheme: String) async -> URL? {
    guard state.isSignedIn, let token = storedToken else { return nil }
    let server = serverURL
    do {
      let ott = try await client.generateOneTimeToken(token: token)
      guard storedToken == token, serverURL == server else { return nil }
      var url = URLComponents(
        url: server.appendingPathComponent("auth/connect/\(provider.rawValue)"), resolvingAgainstBaseURL: false)!
      url.queryItems = [URLQueryItem(name: "app", value: scheme)]
      var fragment = URLComponents()
      fragment.queryItems = [URLQueryItem(name: "ott", value: ott)]
      url.percentEncodedFragment = fragment.percentEncodedQuery
      return url.url
    } catch {
      guard storedToken == token, serverURL == server else { return nil }
      lastError = error.localizedDescription
      return nil
    }
  }

  public func deleteAccount() async {
    guard state.isSignedIn, let token = storedToken else { return }
    let server = serverURL
    lastError = nil
    do {
      try await client.deleteAccount(token: token)
      guard storedToken == token, serverURL == server else { return }
      signOut()
    } catch {
      guard storedToken == token, serverURL == server else { return }
      lastError = error.localizedDescription
    }
  }

}
