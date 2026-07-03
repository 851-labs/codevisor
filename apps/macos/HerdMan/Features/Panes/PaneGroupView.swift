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

    private static let barHeight: CGFloat = 32
    private static let minTabWidth: CGFloat = 52
    private static let maxTabWidth: CGFloat = 168
    private static let tabSpacing: CGFloat = 1
    /// Stable coordinate space for tab dragging: translations measured here
    /// don't jump when the dragged tab's own slot moves during a reorder.
    private static let stripSpace = "paneTabStrip"

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
            let isOverflowing = CGFloat(count) * slotWidth + reserved > geometry.size.width

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
                        // High priority so the ScrollView's pan can't steal
                        // the drag mid-reorder; taps still pass through via
                        // the 3pt minimum distance.
                        .highPriorityGesture(reorderGesture(for: pane.id, slotWidth: slotWidth))
                    }
                    addPaneButton
                }
                .coordinateSpace(name: Self.stripSpace)
                .frame(height: Self.barHeight)
                .animation(.snappy(duration: 0.2), value: group.state.panes.map(\.id))
                // Adding/removing tabs animates every tab to its new width
                // instead of snapping.
                .animation(.snappy(duration: 0.2), value: group.state.panes.count)
            }
            // Soften the strip's edges when it overflows into scrolling.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: isOverflowing ? 14 : 0)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: isOverflowing ? 14 : 0)
                }
            )
        }
        .frame(height: Self.barHeight)
    }

    /// Drag-to-reorder: the tab is glued to the pointer horizontally (offset =
    /// pointer translation minus the slots it has already swapped across);
    /// crossing half a neighbor's slot swaps positions and only the neighbors
    /// animate. Translation is measured in the strip's stable coordinate
    /// space so reorders never make it jump.
    private func reorderGesture(for paneId: UUID, slotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.stripSpace))
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

    /// The tab content's horizontal inset.
    private static let contentPadding: CGFloat = 8
    /// The selected tab shape: bottom-anchored, tall enough to read as the
    /// pane's "mouth" opening through the bar's bottom border.
    private static let selectedShapeHeight: CGFloat = 26
    /// The hover pill: an all-corners rounded rect, vertically centered and
    /// clearly distinct from the selected tab shape (Chrome-style).
    private static let hoverShapeHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: 4) {
            fadingName
            closeButton
        }
        .padding(.horizontal, Self.contentPadding)
        .frame(width: width, height: 32)
        .background(alignment: .bottom) {
            if isSelected {
                // Solid; identical to the bar's bottom border so the tab
                // joins it.
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                    .fill(selectedFill)
                    .frame(height: Self.selectedShapeHeight)
            }
        }
        .background {
            if !isSelected && isHovered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: Self.hoverShapeHeight)
            }
        }
        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    /// The name at natural size, masked with a fixed-width trailing fade so
    /// shrinking tabs fade the text before the ✕ instead of truncating with
    /// an ellipsis. Only the text region collapses as the tab narrows — the
    /// paddings and ✕ keep their size at every width.
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
            HStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 10)
            }
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
