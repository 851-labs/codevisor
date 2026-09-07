import Foundation

/// Addresses and shared starting locations, independent of the browser engine.
public enum BrowserLocation {
  /// Convert saved WebKit aliases back to the original origin for Chromium and
  /// for shared pane metadata. WebKit applies its own routing aliases at load time.
  public static func canonicalURL(_ url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let host = (components.host?.lowercased() ?? "").replacingOccurrences(
      of: "codevisor.localhost", with: "proxy.localhost")
    if host == "proxy.localhost" {
      components.host = "localhost"
    } else if host == "ipv6.proxy.localhost" {
      components.host = "[::1]"
    } else if host.hasPrefix("ipv4-127-"), host.hasSuffix(".proxy.localhost") {
      let octets = host.dropFirst(5).dropLast(".proxy.localhost".count).split(separator: "-")
      guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
      components.host = octets.joined(separator: ".")
    }
    return components.url
  }

  public static func display(_ url: URL) -> String {
    guard let url = canonicalURL(url), var host = url.host(percentEncoded: true) else { return url.absoluteString }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
    let standardPort = url.scheme == "https" ? 443 : 80
    return host + (url.port.flatMap { $0 == standardPort ? nil : ":\($0)" } ?? "")
  }

  /// A saved starting location must never replay an OAuth handshake on another
  /// device. Navigation remains local even when the location is shareable.
  public static func sharedURL(_ input: String) -> URL? {
    guard let url = navigationURL(input), let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    var keys = Set((components.queryItems ?? []).map { $0.name.lowercased() })
    if let fragment = components.fragment,
      let query = URLComponents(string: "https://callback.invalid/?\(fragment)")?.queryItems
    {
      keys.formUnion(query.map { $0.name.lowercased() })
    }
    let privateKeys: Set<String> = [
      "code", "state", "access_token", "id_token", "refresh_token", "oauth_token",
      "oauth_verifier", "code_verifier", "samlresponse", "session_state", "password",
    ]
    return keys.isDisjoint(with: privateKeys) ? url : nil
  }

  /// Bare local addresses default to HTTP; public hostnames default to HTTPS.
  public static func navigationURL(_ input: String) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
    let candidate: String
    if text.contains("://") {
      candidate = text
    } else {
      let host = text.split(separator: "/").first.map(String.init) ?? text
      let local =
        host == "localhost" || host.hasPrefix("localhost:")
        || host.hasPrefix("127.") || host.hasSuffix(".localhost")
        || host.hasPrefix("[::1]") || host.contains(":")
      candidate = "\(local ? "http" : "https")://\(text)"
    }
    guard let url = URL(string: candidate), let host = url.host, !host.isEmpty,
      ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil,
      url.port.map({ (1...65535).contains($0) }) ?? true
    else { return nil }
    return canonicalURL(url)
  }

  /// Interpret typed text separately from URLs supplied by pages or saved panes.
  public static func addressBarURL(_ input: String) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let components = URLComponents(string: "https://\(text)")
    let host = components?.host ?? ""
    let looksLikeAddress =
      !text.contains(where: \.isWhitespace) && !host.isEmpty
      && (host == "localhost" || host.contains(".") || host.hasPrefix("[")
        || components?.port != nil || text.contains("/"))
    let explicitScheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
    if explicitScheme || looksLikeAddress { return navigationURL(text) }

    var search = URLComponents()
    search.scheme = "https"
    search.host = "www.google.com"
    search.path = "/search"
    search.queryItems = [URLQueryItem(name: "q", value: text)]
    // Google decodes '+' as a space, while URLQueryItem leaves it unescaped.
    search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return search.url
  }

}
