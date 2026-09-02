// CrossKit-style platform shims (naming precedent: the vendored GhosttySwift
// helpers). Shared views use these instead of touching AppKit/UIKit directly.
import SwiftUI
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

#if canImport(AppKit)
  public typealias OSColor = NSColor
  public typealias OSFont = NSFont
  public typealias OSImage = NSImage
#elseif canImport(UIKit)
  public typealias OSColor = UIColor
  public typealias OSFont = UIFont
  public typealias OSImage = UIImage
#endif

/// The general pasteboard, platform-neutrally.
public enum PlatformPasteboard {
  @MainActor
  public static func copy(_ string: String) {
    #if canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(string, forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string = string
    #endif
  }
}
