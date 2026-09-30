import SwiftUI

/// Style for bare glyph icon buttons (attach, plan/goal toggles, message
/// copy) and text chips (composer dropdowns): no chrome at rest, a quiet
/// fill while hovered, and a slight dim while pressed — matching the stop
/// button's hover treatment. Composer icon buttons use the circular fill;
/// transcript buttons the rounded rectangle; menu chips the chip variant.
public struct HoverIconButtonStyle: ButtonStyle {
  public enum HighlightShape: Shape {
    case circle
    case roundedRectangle
    /// Text chips: the hover fill bleeds a few points past the label on
    /// every side (via negative padding) so the highlight has breathing
    /// room without shifting the chip's layout.
    case chip

    public func path(in rect: CGRect) -> Path {
      switch self {
      case .circle: Circle().path(in: rect)
      case .roundedRectangle: RoundedRectangle(cornerRadius: 6, style: .continuous).path(in: rect)
      case .chip: Capsule().path(in: rect)
      }
    }

    /// The hover background includes these insets even though the chip
    /// gives them back to its parent (`hoverChipOverflow()`) to keep the
    /// toolbar compact.
    fileprivate var chipInsets: CGSize {
      self == .chip ? HoverIconButtonStyle.chipOverflow : .zero
    }
  }

  var shape: HighlightShape = .circle

  /// How far a chip's hover fill reaches past its label on each side.
  public static let chipOverflow = CGSize(width: 5, height: 3)

  public init(shape: HighlightShape = .circle) {
    self.shape = shape
  }

  public func makeBody(configuration: Configuration) -> some View {
    HoverIconButtonBody(configuration: configuration, shape: shape)
  }
}

private struct HoverIconButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let shape: HoverIconButtonStyle.HighlightShape
  @State private var isHovered = false

  public var body: some View {
    configuration.label
      // Breathing room between the glyph and the hover fill's edge.
      // Circle buttons skip it: their 26pt label frames already are the
      // fill size shared with the chips and the stop/send buttons.
      .padding(.horizontal, chipInsets.width + edgePadding)
      .padding(.vertical, chipInsets.height + edgePadding)
      // Chips sit close to the icon buttons' fill height so the row's
      // highlights read as one family.
      .frame(minHeight: shape == .chip ? 26 : nil)
      .background(shape.fill(isHovered ? Color.primary.opacity(0.06) : .clear))
      // The whole visible fill is the click target, and hovering it is
      // what lights it up. The button keeps this full size: SwiftUI only
      // delivers clicks inside a button's own frame, so giving the chip
      // padding back here (as this style once did) left the fill's edges
      // highlighting but ignoring clicks. Chips give it back outside the
      // button instead, with `hoverChipOverflow()`.
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .opacity(configuration.isPressed ? 0.8 : 1)
  }

  private var edgePadding: CGFloat {
    shape == .circle ? 0 : 1
  }

  private var chipInsets: CGSize {
    shape.chipInsets
  }
}

extension View {
  /// Gives a `.chip`-styled button's hover padding back to its parent so the
  /// fill overflows the label instead of pushing the row apart. Apply it to
  /// the button itself (after `buttonStyle`), never inside the style, so the
  /// button's clickable frame still covers the whole fill.
  public func hoverChipOverflow() -> some View {
    padding(.horizontal, -HoverIconButtonStyle.chipOverflow.width)
      .padding(.vertical, -HoverIconButtonStyle.chipOverflow.height)
  }
}
