#if canImport(UIKit)
  import UIKit

  extension UIFont {
    public static func scaledMonospacedSystemFont(
      forTextStyle textStyle: UIFont.TextStyle,
      weight: UIFont.Weight = .regular
    ) -> UIFont {
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
