import SwiftUI

// Scaling primitives for Dynamic Type (HIG "Supporting Dynamic Type").
//
// Fixed `.frame(width:/height:)` values around text or SF Symbols are latent
// accessibility clips: the content grows with the user's text size while the
// frame stays frozen. `scaledFrame` keeps the same base dimensions at the
// default (Large) content size and grows them in step with a text style, the
// same way the paired text does.
//
// On macOS there is no Dynamic Type, so `@ScaledMetric` never scales and
// `scaledFrame` behaves exactly like `.frame` — the modifier is safe to use
// in shared CodevisorUI views.

private struct ScaledFrameModifier: ViewModifier {
    @ScaledMetric private var scale: CGFloat
    private let width: CGFloat?
    private let height: CGFloat?
    private let alignment: Alignment

    init(
        width: CGFloat?,
        height: CGFloat?,
        relativeTo textStyle: Font.TextStyle,
        alignment: Alignment
    ) {
        self.width = width
        self.height = height
        self.alignment = alignment
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: textStyle)
    }

    func body(content: Content) -> some View {
        content.frame(
            width: width.map { $0 * scale },
            height: height.map { $0 * scale },
            alignment: alignment
        )
    }
}

extension View {
    /// A `.frame` whose dimensions scale with Dynamic Type, relative to
    /// `textStyle`. Use in place of fixed frames around text, SF Symbols,
    /// badges, and icon columns so containers grow with their content.
    ///
    /// `width`/`height` are the base dimensions at the default (Large)
    /// content size.
    public func scaledFrame(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        relativeTo textStyle: Font.TextStyle = .body,
        alignment: Alignment = .center
    ) -> some View {
        modifier(
            ScaledFrameModifier(
                width: width,
                height: height,
                relativeTo: textStyle,
                alignment: alignment
            )
        )
    }
}

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
