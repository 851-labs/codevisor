import Foundation

struct WebPaneOrigin: Equatable {
  var scheme: String
  var host: String
  var port: Int

  init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
    else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = url.port ?? Self.defaultPort(scheme: scheme)
  }

  private static func defaultPort(scheme: String) -> Int {
    switch scheme {
    case "https": 443
    case "http": 80
    default: -1
    }
  }
}
