import Foundation

nonisolated enum BrowserFaviconOrigin {
  static func of(_ page: String?) -> String? {
    guard let page, let components = URLComponents(string: page),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }

    let port = components.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }
}
