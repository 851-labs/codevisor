//  The session bottom pane group's chrome: the always-visible tab bar (whose
//  top edge doubles as the drag-to-resize handle) and the selected pane's
//  content. Tabs behave like Chrome's: equal widths that shrink together as
//  tabs are added (down to a minimum, then the strip scrolls), names fade out
//  instead of truncating, drag the tab itself to reorder, and the selected
//  tab visually connects to the pane below by cutting through the bar's
//  bottom border.

import SwiftUI
import AppKit
import HerdManCore

/// The tab bar: pane tabs + "new terminal" button on the left, the bottom
/// panel toggle on the right. Always visible; when the group is collapsed it
/// sits at the bottom of the session screen and tab clicks re-expand it.
struct PaneGroupBar: View {
    @Environment(\.theme) private var theme
    var group: PaneGroupModel
    var onToggle: () -> Void

    @State private var dragStartHeight: CGFloat?
    // Tab reordering: the tab itself follows the pointer horizontally while
    // its neighbors flow around it.
    @State private var draggingPaneId: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragAdjustment: CGFloat = 0

    private static let barHeight: CGFloat = 28
    private static let minTabWidth: CGFloat = 72
    private static let maxTabWidth: CGFloat = 168
    private static let tabSpacing: CGFloat = 1

    var body: some View {
        HStack(spacing: 8) {
            tabsArea
            toggleButton
        }
        .padding(.horizontal, 10)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        // The bottom border draws directly behind the tabs so the selected
        // tab (whose fill is the exact same solid color) covers it —
        // Chrome-style "the tab opens into the pane". Window background sits
        // behind both.
        .background(alignment: .bottom) {
            if group.state.isVisible {
                Rectangle()
                    .fill(connectedTabColor)
                    .frame(height: 1)
            }
        }
        .background(theme.windowBackground)
        .overlay(alignment: .top) { Divider() }
        // Only the bar's top edge is the resize handle (and shows the resize
        // cursor); the rest of the bar keeps the default cursor.
        .overlay(alignment: .top) { resizeHandle }
    }

    /// The solid color shared by the bar's bottom border and the selected
    /// tab: the (usually translucent) separator flattened over the window
    /// background, so the tab and border match perfectly with no transparency.
    private var connectedTabColor: Color {
        guard
            let top = NSColor(theme.separator).usingColorSpace(.sRGB),
            let bottom = NSColor(theme.windowBackground).usingColorSpace(.sRGB)
        else { return theme.separator }
        let alpha = top.alphaComponent
        return Color(
            red: Double(top.redComponent * alpha + bottom.redComponent * (1 - alpha)),
            green: Double(top.greenComponent * alpha + bottom.greenComponent * (1 - alpha)),
            blue: Double(top.blueComponent * alpha + bottom.blueComponent * (1 - alpha))
        )
    }

    // MARK: - Tabs

    private var tabsArea: some View {
        GeometryReader { geometry in
            let reserved: CGFloat = 20 + 4 // add button + its spacing
            let available = max(geometry.size.width - reserved, Self.minTabWidth)
            let count = max(group.state.panes.count, 1)
            let tabWidth = min(Self.maxTabWidth, max(Self.minTabWidth, available / CGFloat(count)))
            let slotWidth = tabWidth + Self.tabSpacing

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.tabSpacing) {
                    ForEach(group.state.panes) { pane in
                        PaneTab(
                            name: pane.name,
                            isSelected: pane.id == group.state.selectedPaneId,
                            isDragging: draggingPaneId == pane.id,
                            width: tabWidth,
                            selectedFill: connectedTabColor,
                            onSelect: {
                                group.select(id: pane.id)
                                group.focusSelectedPane()
                            },
                            onClose: { group.closePane(id: pane.id) }
                        )
                        .offset(x: draggingPaneId == pane.id ? dragOffset : 0)
                        .zIndex(draggingPaneId == pane.id ? 1 : 0)
                        // The dragged tab tracks the pointer directly: its own
                        // slot shifts must not animate (the offset compensates
                        // instantly), while neighbors animate via the HStack.
                        .transaction { transaction in
                            if draggingPaneId == pane.id { transaction.animation = nil }
                        }
                        .gesture(reorderGesture(for: pane.id, slotWidth: slotWidth))
                    }
                    addPaneButton
                }
                .frame(height: Self.barHeight)
                .animation(.snappy(duration: 0.2), value: group.state.panes.map(\.id))
            }
        }
        .frame(height: Self.barHeight)
    }

    /// Drag-to-reorder: the tab follows the pointer horizontally; crossing
    /// half a neighbor's slot swaps positions (neighbors animate around it).
    private func reorderGesture(for paneId: UUID, slotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if draggingPaneId != paneId {
                    draggingPaneId = paneId
                    dragAdjustment = 0
                }
                var offset = value.translation.width + dragAdjustment
                while offset > slotWidth / 2, let next = neighborId(of: paneId, direction: 1) {
                    group.movePane(id: paneId, onto: next)
                    dragAdjustment -= slotWidth
                    offset -= slotWidth
                }
                while offset < -slotWidth / 2, let previous = neighborId(of: paneId, direction: -1) {
                    group.movePane(id: paneId, onto: previous)
                    dragAdjustment += slotWidth
                    offset += slotWidth
                }
                dragOffset = offset
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) {
                    dragOffset = 0
                }
                draggingPaneId = nil
                dragAdjustment = 0
            }
    }

    private func neighborId(of paneId: UUID, direction: Int) -> UUID? {
        guard let index = group.state.panes.firstIndex(where: { $0.id == paneId }) else { return nil }
        let neighbor = index + direction
        guard group.state.panes.indices.contains(neighbor) else { return nil }
        return group.state.panes[neighbor].id
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
/// close button on hover/selection. The tab shape hugs the bar's bottom (with
/// clearance below the resize strip); the selected tab's solid fill matches
/// the bottom border so it reads as connected to the pane.
private struct PaneTab: View {
    @Environment(\.theme) private var theme
    let name: String
    let isSelected: Bool
    let isDragging: Bool
    let width: CGFloat
    let selectedFill: Color
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    /// The tab shape's height: bottom-anchored, leaving the resize strip and
    /// a little air above it.
    private static let shapeHeight: CGFloat = 21

    var body: some View {
        HStack(spacing: 4) {
            fadingName
            closeButton
                .opacity(isHovered || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 28)
        .background(alignment: .bottom) {
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                .fill(background)
                .frame(height: Self.shapeHeight)
        }
        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected {
            // Solid; identical to the bar's bottom border so the tab joins it.
            return selectedFill
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
