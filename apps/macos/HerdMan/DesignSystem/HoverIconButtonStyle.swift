import SwiftUI

/// Style for bare glyph icon buttons (attach, plan/goal toggles, message
/// copy) and text chips (composer dropdowns): no chrome at rest, a quiet
/// fill while hovered, and a slight dim while pressed — matching the stop
/// button's hover treatment. Composer icon buttons use the circular fill;
/// transcript buttons the rounded rectangle; menu chips the chip variant.
struct HoverIconButtonStyle: ButtonStyle {
    enum HighlightShape {
        case circle
        case roundedRectangle
        /// Text chips: the hover fill bleeds a few points past the label on
        /// every side (via negative padding) so the highlight has breathing
        /// room without shifting the chip's layout.
        case chip
    }

    var shape: HighlightShape = .circle

    func makeBody(configuration: Configuration) -> some View {
        HoverIconButtonBody(configuration: configuration, shape: shape)
    }
}

private struct HoverIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: HoverIconButtonStyle.HighlightShape
    @State private var isHovered = false

    var body: some View {
        configuration.label
            // Breathing room between the glyph and the hover fill's edge.
            // Circle buttons skip it: their 26pt label frames already are the
            // fill size shared with the chips and the stop/send buttons.
            .padding(.horizontal, chipInsets.width + edgePadding)
            .padding(.vertical, chipInsets.height + edgePadding)
            // Chips sit close to the icon buttons' fill height so the row's
            // highlights read as one family.
            .frame(minHeight: shape == .chip ? 26 : nil)
            .background(highlightShape.fill(isHovered ? Color.primary.opacity(0.06) : .clear))
            // Chips give the padding back so the fill overflows the label
            // instead of pushing the row apart.
            .padding(.horizontal, -chipInsets.width)
            .padding(.vertical, -chipInsets.height)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { isHovered = $0 }
    }

    private var edgePadding: CGFloat {
        shape == .circle ? 0 : 1
    }

    private var chipInsets: CGSize {
        switch shape {
        case .chip: CGSize(width: 5, height: 3)
        case .circle, .roundedRectangle: .zero
        }
    }

    private var highlightShape: AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .chip: AnyShape(Capsule())
        }
    }
}
