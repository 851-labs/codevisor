#if canImport(UIKit)
  import UIKit

  extension UIFont {
    /// A monospaced system font pinned to a text style's hierarchy and
    /// scaled through `UIFontMetrics`, so UIKit rescales it in place when
    /// the content size category changes (`adjustsFontForContentSizeCategory`).
    ///
    /// Use instead of the fragile
    /// `monospacedSystemFont(ofSize: preferredFont(forTextStyle:).pointSize)`
    /// idiom, which produces a font UIKit cannot rescale — it only tracks
    /// Dynamic Type if SwiftUI happens to rebuild the hosting view.
    ///
    /// Lives in StreamMarkdown (rather than CodevisorUI) because the
    /// markdown/transcript rendering stack is its main consumer and
    /// CodevisorUI already depends on this package.
    public static func scaledMonospacedSystemFont(
      forTextStyle textStyle: UIFont.TextStyle,
      weight: UIFont.Weight = .regular
    ) -> UIFont {
      // Base size must come from the default (Large) category — the
      // metrics below apply the user's current category on top, and
      // reading `preferredFont` without pinning would double-scale.
      let baseDescriptor = UIFontDescriptor.preferredFontDescriptor(
        withTextStyle: textStyle,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
      )
      let base = UIFont.monospacedSystemFont(
        ofSize: baseDescriptor.pointSize,
        weight: weight
      )
      return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }
  }
#endif
