import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// A harness's brand glyph from the app's `harness-<id>` asset (the bundled
/// lobe-icons set), template-rendered so it follows the foreground style;
/// an SF Symbol when the harness has no bundled icon.
public struct HarnessGlyph: View {
  let harnessId: String?
  let fallbackSymbolName: String
  let size: CGFloat

  public init(harnessId: String?, fallbackSymbolName: String = "sparkle", size: CGFloat) {
    self.harnessId = harnessId
    self.fallbackSymbolName = fallbackSymbolName
    self.size = size
  }

  private var assetName: String? {
    guard let harnessId, !harnessId.isEmpty else { return nil }
    let name = "harness-\(harnessId)"
    #if canImport(UIKit)
      return UIImage(named: name) == nil ? nil : name
    #else
      return NSImage(named: name) == nil ? nil : name
    #endif
  }

  public var body: some View {
    if let assetName {
      Image(assetName)
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .frame(width: size, height: size)
    } else {
      Image(systemName: fallbackSymbolName)
        .font(.system(size: size - 1, weight: .medium))
    }
  }
}
