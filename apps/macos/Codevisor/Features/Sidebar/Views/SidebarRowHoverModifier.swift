import CodevisorTheming
import CodevisorUI
import SwiftUI

/// The background-only variant for rows without hover-revealed content.
struct SidebarRowHoverModifier: ViewModifier {
    var isSelected = false
    var isEnabled = true
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let showsHover = controlActiveState == .key && isEnabled && isHovered
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? theme.rowSelectedBackground
                            : (showsHover ? theme.rowHoverBackground : .clear))
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Sidebar row hover/selection background with row-local hover state.
    func sidebarRowHover(isSelected: Bool = false, isEnabled: Bool = true) -> some View {
        modifier(SidebarRowHoverModifier(isSelected: isSelected, isEnabled: isEnabled))
    }
}
