//  The session bottom pane group's chrome: the always-visible tab bar (whose
//  top edge doubles as the drag-to-resize handle) and the selected pane's
//  content. Tabs behave like Chrome's: equal widths that shrink together as
//  tabs are added (down to a minimum, then the strip scrolls), names fade out
//  instead of truncating, drag to reorder, and the selected tab visually
//  connects to the pane below by cutting through the bar's bottom border.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HerdManCore

/// The tab bar: pane tabs + "new terminal" button on the left, the bottom
/// panel toggle on the right. Always visible; when the group is collapsed it
/// sits at the bottom of the session screen and tab clicks re-expand it.
struct PaneGroupBar: View {
    @Environment(\.theme) private var theme
    var group: PaneGroupModel
    var onToggle: () -> Void

    @State private var dragStartHeight: CGFloat?
    @State private var draggingPaneId: UUID?

    private static let barHeight: CGFloat = 28
    private static let minTabWidth: CGFloat = 72
    private static let maxTabWidth: CGFloat = 168

    var body: some View {
        HStack(spacing: 8) {
            tabsArea
            toggleButton
        }
        .padding(.horizontal, 10)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        // The bottom border draws directly behind the tabs so the selected
        // tab (whose fill matches it) covers it — Chrome-style "the tab opens
        // into the pane". Window background sits behind both.
        .background(alignment: .bottom) {
            if group.state.isVisible {
                Rectangle()
                    .fill(theme.separator)
                    .frame(height: 1)
            }
        }
        .background(theme.windowBackground)
        .overlay(alignment: .top) { Divider() }
        // Only the bar's top edge is the resize handle (and shows the resize
        // cursor); the rest of the bar keeps the default cursor.
        .overlay(alignment: .top) { resizeHandle }
    }

    // MARK: - Tabs

    private var tabsArea: some View {
        GeometryReader { geometry in
            let reserved: CGFloat = 20 + 4 // add button + its spacing
            let available = max(geometry.size.width - reserved, Self.minTabWidth)
            let count = max(group.state.panes.count, 1)
            let tabWidth = min(Self.maxTabWidth, max(Self.minTabWidth, available / CGFloat(count)))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(group.state.panes) { pane in
                        PaneTab(
                            name: pane.name,
                            isSelected: pane.id == group.state.selectedPaneId,
                            width: tabWidth,
                            isDragging: draggingPaneId == pane.id,
                            onSelect: {
                                group.select(id: pane.id)
                                group.focusSelectedPane()
                            },
                            onClose: { group.closePane(id: pane.id) }
                        )
                        .onDrag {
                            draggingPaneId = pane.id
                            return NSItemProvider(object: pane.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: PaneTabDropDelegate(
                                targetId: pane.id,
                                draggingId: $draggingPaneId,
                                group: group
                            )
                        )
                    }
                    addPaneButton
                }
                .frame(height: Self.barHeight)
            }
        }
        .frame(height: Self.barHeight)
    }

    private var addPaneButton: some View {
        Button {
            group.addTerminalPane()
            // Defer until SwiftUI has mounted the new pane's view.
            DispatchQueue.main.async { group.focusSelectedPane() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New terminal")
    }

    private var toggleButton: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: "rectangle.bottomthird.inset.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(group.state.isVisible ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle bottom panel (⌘J)")
    }

    // MARK: - Resize

    /// A thin strip on the bar's top edge: the only place that shows the
    /// resize cursor and accepts the resize drag (drag up = taller). Only
    /// active while the panel is open.
    @ViewBuilder
    private var resizeHandle: some View {
        if group.state.isVisible {
            Color.clear
                .frame(height: 6)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(resizeGesture)
        }
    }

    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartHeight ?? group.state.height
                dragStartHeight = start
                group.setHeight(start - value.translation.height)
            }
            .onEnded { _ in
                if dragStartHeight != nil {
                    group.setHeight(group.state.height, isFinal: true)
                }
                dragStartHeight = nil
            }
    }
}

/// One tab: pane name (fading out as space shrinks, never truncating) plus a
/// close button on hover/selection. The selected tab fills the full bar
/// height with the bottom-border color so it reads as connected to the pane.
private struct PaneTab: View {
    @Environment(\.theme) private var theme
    let name: String
    let isSelected: Bool
    let width: CGFloat
    let isDragging: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            fadingName
            closeButton
                .opacity(isHovered || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                .fill(background)
        )
        .opacity(isDragging ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected {
            // Must match the bar's bottom border so the tab covers/joins it.
            return theme.separator
        }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }

    /// The name at natural size, masked with a trailing fade so shrinking
    /// tabs fade the text before the ✕ instead of truncating with an ellipsis.
    private var fadingName: some View {
        ZStack(alignment: .leading) {
            Text(name)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close terminal")
    }
}

/// Reorders tabs live while a drag hovers over them (Chrome-style swap-flow),
/// animated per the HIG's guidance on direct-manipulation feedback.
private struct PaneTabDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draggingId: UUID?
    let group: PaneGroupModel

    func validateDrop(info: DropInfo) -> Bool {
        draggingId != nil
    }

    func dropEntered(info: DropInfo) {
        guard let draggingId, draggingId != targetId else { return }
        withAnimation(.snappy(duration: 0.25)) {
            group.movePane(id: draggingId, onto: targetId)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}

/// The selected pane's content, mounted only while the group is open. Panes
/// cache their expensive backing state (the terminal caches its NSView), so
/// switching tabs restores rather than rebuilds.
struct PaneGroupContent: View {
    var group: PaneGroupModel

    var body: some View {
        if let pane = group.selectedPane {
            pane.makeView()
                .id(pane.id)
        }
    }
}
