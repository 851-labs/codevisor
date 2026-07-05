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
    /// Chrome-style close behavior: closing a tab freezes tab widths (the
    /// remaining tabs just slide over, keeping the next ✕ under the pointer)
    /// until the pointer leaves the strip, then widths relax to fit.
    @State private var frozenTabWidth: CGFloat?
    /// Which strip edges currently hide content (drives the edge fades).
    @State private var scrollEdges = StripScrollEdges()

    private static let barHeight: CGFloat = 32
    /// Scrolling is a last resort: tabs compress hard before overflowing.
    private static let minTabWidth: CGFloat = 36
    private static let maxTabWidth: CGFloat = 168
    /// Below this width, non-selected tabs hide their ✕ to give text room.
    private static let closeButtonMinWidth: CGFloat = 88
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
        // behind both. Always in the layout (fading via opacity) so it moves
        // with the bar during the open/close animation instead of popping in
        // at the bar's final position.
        .background(alignment: .bottom) {
            Rectangle()
                .fill(connectedTabColor)
                .frame(height: 1)
                .opacity(group.state.isVisible ? 1 : 0)
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
            let fittedWidth = min(Self.maxTabWidth, max(Self.minTabWidth, available / CGFloat(count)))
            let tabWidth = frozenTabWidth ?? fittedWidth
            let slotWidth = tabWidth + Self.tabSpacing
            let contentWidth = CGFloat(count) * slotWidth
            let isOverflowing = contentWidth > available

            // The strip hugs its tabs so the add button sits right after the
            // last tab (Chrome-style), pinned at the edge once tabs overflow
            // into scrolling.
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    tabRow(tabWidth: tabWidth, slotWidth: slotWidth)
                }
                // No scrolling (or rubber-band overscroll) while everything fits.
                .scrollDisabled(!isOverflowing)
                .onScrollGeometryChange(for: StripScrollEdges.self) { geometry in
                    StripScrollEdges(
                        hidesLeading: geometry.contentOffset.x > 1,
                        hidesTrailing: geometry.contentOffset.x + geometry.containerSize.width
                            < geometry.contentSize.width - 1
                    )
                } action: { _, edges in
                    scrollEdges = edges
                }
                .frame(width: min(contentWidth, available), alignment: .leading)
                // Fade only the edges that actually hide content: no fade at
                // an edge you're fully scrolled against.
                .mask(
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: scrollEdges.hidesLeading ? 14 : 0)
                        Rectangle().fill(.black)
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: scrollEdges.hidesTrailing ? 14 : 0)
                    }
                    .animation(.easeOut(duration: 0.15), value: scrollEdges)
                )
                // Pointer left the strip: relax frozen widths back to fitting.
                .onHover { hovering in
                    guard !hovering, frozenTabWidth != nil else { return }
                    withAnimation(.snappy(duration: 0.2)) { frozenTabWidth = nil }
                }

                // Always in the layout (fading via opacity) so it rides the
                // bar's open/close animation instead of appearing detached at
                // the final position.
                addPaneButton
                    .opacity(group.state.isVisible ? 1 : 0)
                    .allowsHitTesting(group.state.isVisible)

                Spacer(minLength: 0)
            }
            .animation(.snappy(duration: 0.2), value: group.state.panes.map(\.id))
            .animation(.snappy(duration: 0.2), value: group.state.panes.count)
        }
        .frame(height: Self.barHeight)
    }

    private func tabRow(tabWidth: CGFloat, slotWidth: CGFloat) -> some View {
        // While the group is collapsed no tab reads as selected: every tab
        // shows only its hover affordance, and clicking one opens the panel
        // to that tab (select() expands the group). ⌘J/the toggle button
        // reopen to state.selectedPaneId, which is still tracked underneath.
        let showsSelection = group.state.isVisible
        return HStack(spacing: Self.tabSpacing) {
            ForEach(group.state.panes) { pane in
                        PaneTab(
                            name: pane.name,
                            isSelected: showsSelection && pane.id == group.state.selectedPaneId,
                            isDragging: draggingPaneId == pane.id,
                            width: tabWidth,
                            // No ✕ while the panel is collapsed; when open,
                            // narrow tabs drop the ✕ on non-selected tabs so
                            // the name keeps as much room as possible.
                            showsClose: showsSelection
                                && (pane.id == group.state.selectedPaneId
                                    || tabWidth >= Self.closeButtonMinWidth),
                            selectedFill: connectedTabColor,
                            onSelect: {
                                group.select(id: pane.id)
                                group.focusSelectedPane()
                            },
                            onClose: {
                                // Freeze widths so remaining tabs slide over
                                // without resizing (see frozenTabWidth).
                                frozenTabWidth = tabWidth
                                group.closePane(id: pane.id)
                            }
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
                        // New tabs grow in from zero width (and closing tabs
                        // shrink away), naturally resizing/sliding the rest.
                        .transition(.modifier(
                            active: TabSlotWidthModifier(width: 0, clips: true),
                            identity: TabSlotWidthModifier(width: tabWidth, clips: false)
                        ))
            }
        }
        .coordinateSpace(name: Self.stripSpace)
        .frame(height: Self.barHeight)
        // Kill horizontal rubber-banding on the strip entirely.
        .background(StripElasticityDisabler())
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
                    // Dragging always operates on the selected tab: picking up
                    // an unselected tab selects it first (Chrome behavior).
                    if group.state.selectedPaneId != paneId {
                        group.select(id: paneId)
                    }
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
                // Clamp to the strip: the tab can't be dragged past the
                // first/last slot (it would escape the scroll clip).
                if let index = group.state.panes.firstIndex(where: { $0.id == paneId }) {
                    let minOffset = -CGFloat(index) * slotWidth
                    let maxOffset = CGFloat(group.state.panes.count - 1 - index) * slotWidth
                    offset = min(max(offset, minOffset), maxOffset)
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
            frozenTabWidth = nil
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
                .foregroundStyle(group.state.isVisible ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
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

/// Which edges of the tab strip currently hide scrolled-out content.
private struct StripScrollEdges: Equatable {
    var hidesLeading = false
    var hidesTrailing = false
}

/// Disables horizontal elasticity (overscroll rubber-banding) on the
/// enclosing NSScrollView — SwiftUI exposes no never-bounce API on macOS.
private struct StripElasticityDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            var ancestor: NSView? = view
            while let current = ancestor, !(current is NSScrollView) {
                ancestor = current.superview
            }
            (ancestor as? NSScrollView)?.horizontalScrollElasticity = .none
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Animates a tab's slot width during insertion/removal transitions: new tabs
/// grow in from zero and closing tabs collapse, sliding their neighbors.
/// Clipping applies only in the transition's active state — the identity
/// state must not clip, or dragged tabs get sheared at their slot bounds.
private struct TabSlotWidthModifier: ViewModifier {
    let width: CGFloat
    var clips = false

    func body(content: Content) -> some View {
        content
            .frame(width: width, alignment: .leading)
            // A hugely-inset-out rectangle disables clipping without changing
            // the view structure between transition states.
            .clipShape(Rectangle().inset(by: clips ? 0 : -10_000))
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
    let showsClose: Bool
    let selectedFill: Color
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @State private var isCloseHovered = false

    /// The tab content's horizontal inset.
    private static let contentPadding: CGFloat = 8
    /// The hover pill: an all-corners rounded rect, vertically centered and
    /// clearly distinct from the selected tab shape (Chrome-style). Centered
    /// in the 32pt bar, its top inset is 5pt.
    private static let hoverShapeHeight: CGFloat = 22
    /// The selected tab shape: bottom-anchored, its top edge aligned with the
    /// hover pill's top edge (32 - (32 - 22) / 2) — generous air above the
    /// text row while still opening into the pane below.
    private static let selectedShapeHeight: CGFloat = 27

    var body: some View {
        HStack(spacing: 4) {
            fadingName
            if showsClose {
                closeButton
            }
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
        // minWidth 0 lets the tab compress below the text's natural width —
        // the text then clips behind the ✕ (with the fade) instead of
        // overflowing the tab.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(isCloseHovered ? .primary : .secondary)
                .frame(width: 14, height: 14)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isCloseHovered ? 0.14 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
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
