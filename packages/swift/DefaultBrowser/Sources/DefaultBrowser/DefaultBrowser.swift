import SwiftUI

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

@MainActor
public enum DefaultBrowser {
  @discardableResult
  public static func open(_ url: URL) -> Bool {
    #if canImport(AppKit)
      NSWorkspace.shared.open(url)
    #else
      UIApplication.shared.open(url)
      return true
    #endif
  }

  public static var openURLAction: OpenURLAction {
    OpenURLAction { url in open(url) ? .handled : .discarded }
  }
}

extension View {
  public func opensLinksInDefaultBrowser() -> some View {
    environment(\.openURL, DefaultBrowser.openURLAction)
  }
}
