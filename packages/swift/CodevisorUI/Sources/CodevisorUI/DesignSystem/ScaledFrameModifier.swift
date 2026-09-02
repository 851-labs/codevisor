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

extension View {
  /// Expands a control's tappable area to at least `minimum` points square
  /// (HIG: 44×44 pt) without affecting layout: the hit shape is padded out,
  /// then the layout bounds are pulled back in. `base` is the control's
  /// visible size at the default content size — when the visible control is
  /// already larger (e.g. a `scaledFrame` at accessibility sizes), the hit
  /// area simply grows with it.
  public func expandedHitTarget(base: CGFloat, minimum: CGFloat = 44) -> some View {
    let pad = max(0, (minimum - base) / 2)
    return padding(pad)
      .contentShape(Rectangle())
      .padding(-pad)
  }
}

// Note: the UIKit counterpart, `UIFont.scaledMonospacedSystemFont`, lives in
// StreamMarkdown (which CodevisorUI depends on) so the markdown/transcript
// rendering stack can use it too.
