import Foundation
import Synchronization

#if canImport(UIKit)
  import UIKit

  public enum BodyTextMetrics {
    private struct Resolved: @unchecked Sendable {
      let font: UIFont
    }

    private static let fonts = Mutex<[UIContentSizeCategory: Resolved]>([:])

    public static var font: UIFont {
      font(for: UITraitCollection.current.preferredContentSizeCategory)
    }

    public static func font(for category: UIContentSizeCategory) -> UIFont {
      fonts.withLock { cache in
        if let resolved = cache[category] { return resolved.font }

        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        cache[category] = Resolved(font: font)
        return font
      }
    }

    public static func lineHeight(for category: UIContentSizeCategory) -> CGFloat {
      font(for: category).lineHeight
    }
  }
#else
  import AppKit

  public enum BodyTextMetrics {
    private struct Resolved: @unchecked Sendable {
      let font: NSFont
      let lineHeight: CGFloat
    }

    private static let resolved = Mutex<Resolved?>(nil)

    public static var font: NSFont { current.font }

    public static var lineHeight: CGFloat { current.lineHeight }

    private static var current: Resolved {
      resolved.withLock { cached in
        if let cached { return cached }

        let font = NSFont.preferredFont(forTextStyle: .body)
        let value = Resolved(font: font, lineHeight: NSLayoutManager().defaultLineHeight(for: font))
        cached = value
        return value
      }
    }
  }
#endif
