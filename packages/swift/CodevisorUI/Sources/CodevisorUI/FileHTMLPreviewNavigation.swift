import Foundation

enum FileHTMLPreviewNavigation: Equatable {
  case allow
  case cancel
  case openFile(String)
  case openWebLink(URL)
  case openExternally(URL)

  private static let frameSchemes: Set<String> = [
    "about", "data", "blob", "http", "https", FileHTMLPreviewAddress.scheme,
  ]

  static func decide(
    url: URL?, isMainFrame: Bool, isLinkActivated: Bool, address: FileHTMLPreviewAddress
  ) -> FileHTMLPreviewNavigation {
    guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
    guard isMainFrame else { return frameSchemes.contains(scheme) ? .allow : .cancel }
    if address.isPage(url) { return .allow }
    guard isLinkActivated else { return .cancel }
    return link(url)
  }

  static func link(_ url: URL) -> FileHTMLPreviewNavigation {
    switch url.scheme?.lowercased() {
    case FileHTMLPreviewAddress.scheme:
      FileHTMLPreviewAddress.path(of: url).map { .openFile(target($0, fragment: url.fragment)) } ?? .cancel
    case "file": .openFile(target(url.path(percentEncoded: false), fragment: url.fragment))
    case "http", "https": .openWebLink(url)
    case "mailto": .openExternally(url)
    default: .cancel
    }
  }

  private static func target(_ path: String, fragment: String?) -> String {
    guard let fragment, !fragment.isEmpty else { return path }
    return path + "#" + fragment
  }
}
