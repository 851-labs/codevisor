import Foundation
import Network

/// Literal loopback destinations bypass WebKit proxies. A .localhost alias
/// still has localhost secure-context semantics, but uses the configured proxy.
enum BrowserAddress {
  /// Keep the actual origin recognizable while omitting navigation details.
  /// Never reduce a hostname to its last two labels (for example, co.uk).
  static func display(_ url: URL) -> String {
    guard var host = url.host(percentEncoded: true) else { return url.absoluteString }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
    let standardPort = url.scheme == "https" ? 443 : 80
    return host + (url.port.flatMap { $0 == standardPort ? nil : ":\($0)" } ?? "")
  }

  static func proxied(_ url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      let rawHost = components.host?.lowercased()
    else { return nil }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host == "localhost." || host == "0.0.0.0" {
      components.host = "proxy.localhost"
    } else if let address = IPv4Address(host), address.rawValue.first == 127 {
      components.host = "ipv4-\(address.rawValue.map(String.init).joined(separator: "-")).proxy.localhost"
    } else if let address = IPv6Address(host), address.rawValue == Data(repeating: 0, count: 15) + Data([1]) {
      components.host = "ipv6.proxy.localhost"
    }
    return components.url
  }
}
