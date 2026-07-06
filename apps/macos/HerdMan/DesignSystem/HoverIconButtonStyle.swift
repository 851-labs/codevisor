import SwiftUI

/// Style for bare glyph icon buttons (attach, plan/goal toggles, message
/// copy): no chrome at rest, a quiet fill while hovered, and a slight dim
/// while pressed — matching the stop button's hover treatment. Composer
/// buttons use the circular fill; transcript buttons the rounded rectangle.
struct HoverIconButtonStyle: ButtonStyle {
    enum HighlightShape {
        case circle
        case roundedRectangle
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
            .padding(1)
            .background(highlightShape.fill(isHovered ? Color.primary.opacity(0.06) : .clear))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { isHovered = $0 }
    }

    private var highlightShape: AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
