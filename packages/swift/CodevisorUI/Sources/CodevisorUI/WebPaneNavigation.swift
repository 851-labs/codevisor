import Foundation

enum WebPaneNavigation: Equatable {
  case allow
  case cancel
  case openExternally(URL)

  private static let subframeSchemes: Set<String> = ["about", "data", "blob", "http", "https"]

  static func decide(url: URL?, isMainFrame: Bool?, allowedOrigin: WebPaneOrigin?) -> WebPaneNavigation {
    guard let url else { return .cancel }
    if url.scheme?.lowercased() == "about" { return .allow }
    if isMainFrame == false { return subframe(url) }
    if let allowedOrigin, WebPaneOrigin(url: url) == allowedOrigin { return .allow }
    guard let external = externalURL(url) else { return .cancel }
    return .openExternally(external)
  }

  static func externalURL(_ url: URL) -> URL? {
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto":
      url
    default:
      nil
    }
  }

  private static func subframe(_ url: URL) -> WebPaneNavigation {
    guard let scheme = url.scheme?.lowercased(), subframeSchemes.contains(scheme) else { return .cancel }
    return .allow
  }
}
