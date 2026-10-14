import Foundation

public struct CloudDeviceApprovalLink: Equatable, Hashable, Sendable {
  public var serverURL: URL
  public var userCode: String

  public init(serverURL: URL, userCode: String) {
    self.serverURL = serverURL
    self.userCode = userCode
  }

  public var host: String { Self.displayHost(of: serverURL) }

  public static func parse(_ url: URL) -> CloudDeviceApprovalLink? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(), !host.isEmpty,
      components.user == nil, components.password == nil,
      scheme == "https" || (scheme == "http" && isLoopback(host)),
      components.path == "/device" || components.path == "/device/",
      let code = components.queryItems?
        .first(where: { $0.name == "user_code" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      isPlausibleUserCode(code)
    else { return nil }
    var origin = URLComponents()
    origin.scheme = scheme
    origin.host = host
    origin.port = components.port
    guard let serverURL = origin.url else { return nil }
    return CloudDeviceApprovalLink(serverURL: serverURL, userCode: code)
  }

  public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let left = origin(of: lhs), let right = origin(of: rhs) else { return false }
    return left == right
  }

  static func displayHost(of url: URL) -> String {
    let host = url.host()?.lowercased() ?? url.absoluteString
    guard let port = url.port, port != defaultPort(for: url.scheme) else { return host }
    return "\(host):\(port)"
  }

  private static func origin(of url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else {
      return nil
    }
    let port = url.port ?? defaultPort(for: scheme)
    return "\(scheme)://\(host):\(port.map(String.init) ?? "")"
  }

  private static func defaultPort(for scheme: String?) -> Int? {
    switch scheme?.lowercased() {
    case "https": 443
    case "http": 80
    default: nil
    }
  }

  private static func isLoopback(_ host: String) -> Bool {
    ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
  }

  private static func isPlausibleUserCode(_ code: String) -> Bool {
    (1...32).contains(code.count)
      && code.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
      && code.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "-" || CharacterSet.alphanumerics.contains($0)) }
  }
}
