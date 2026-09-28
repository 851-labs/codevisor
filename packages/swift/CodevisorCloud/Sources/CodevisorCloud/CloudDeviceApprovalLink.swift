import Foundation

/// A parsed device-approval link — the verification page `codevisor auth
/// login` prints as a QR code (`https://<cloud>/device?user_code=XXXX-XXXX`).
/// The cloud's apple-app-site-association routes `/device` into the app, so
/// scanning the code on a phone opens an approval screen instead of the web
/// page. Parsing only extracts the code and the cloud that issued it; the
/// app must still refuse to approve for any cloud other than the account's
/// own (`CloudAccountController.deviceApprovalServerMismatch(for:)`).
public struct CloudDeviceApprovalLink: Equatable, Hashable, Sendable {
  /// The issuing cloud's origin (scheme, host, and port; no path).
  public var serverURL: URL
  /// The user code exactly as the link carried it (the cloud ignores dashes).
  public var userCode: String

  public init(serverURL: URL, userCode: String) {
    self.serverURL = serverURL
    self.userCode = userCode
  }

  /// The issuing cloud's host (with a non-default port), for display.
  public var host: String { Self.displayHost(of: serverURL) }

  /// Accepts `https` links, plus `http` for a loopback dev cloud
  /// (`CODEVISOR_DEV_CLOUD_URL` is a local http Worker). The path must be
  /// `/device` and `user_code` a short alphanumeric code; anything else is
  /// some other page on the site.
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

  /// Whether both URLs name the same origin (scheme, host, effective port),
  /// ignoring any path — a custom server may be configured with one.
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

  /// better-auth issues short uppercase alphanumeric codes; the CLI may
  /// group them with a dash. Anything else is not a code worth showing.
  private static func isPlausibleUserCode(_ code: String) -> Bool {
    (1...32).contains(code.count)
      && code.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
      && code.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "-" || CharacterSet.alphanumerics.contains($0)) }
  }
}
