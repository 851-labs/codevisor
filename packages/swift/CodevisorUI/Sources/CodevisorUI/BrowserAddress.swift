import Foundation
import Network

enum BrowserAddress {
  static func display(_ url: URL) -> String {
    BrowserLocation.display(url)
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
