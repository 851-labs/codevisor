//  A pane group's chrome: the tab bar and the selected pane's content. One
//  bar serves both of a session's groups — the center group hosting the chat
//  (mounted in the window's top bar) and the ⌘J bottom panel (whose bar's
//  top edge doubles as the drag-to-resize handle). Tabs are compact capsules
//  in the toolbar's control language: in the top bar the selected tab is a
//  Liquid Glass capsule beside the window's other glass controls, in
//  content-layer headers it is a quiet selected fill (glass belongs to the
//  chrome layer, not content). Tabs behave like Chrome's: equal widths that
//  shrink together as tabs are added (down to a minimum, then the strip
//  scrolls), names fade out instead of truncating, drag the tab itself to
//  reorder (or into the other bar to move it between groups).

import SwiftUI
import AppKit
import CodevisorCore

/// The tab bar: pane tabs + "new terminal" button on the left and, for the
/// bottom panel, the panel toggle on the right.
struct PaneGroupBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var group: PaneGroupModel
    /// Present when the session screen supports dragging tabs between its
    /// pane groups; nil disables cross-group drags (previews, single-group
    /// hosts).
    var dragCoordinator: PaneTabDragCoordinator?
    /// The display name for the chat tab: the session's live title (the
    /// persisted descriptor name is just a fallback — titles change as the
    /// session is renamed/auto-titled).
    var chatTabTitle: String?
    /// Whether the tabs show their ⌘N shortcut hints (native window tab
    /// bars show them on the bar the shortcuts currently target).
    var showsShortcutHints = false
    /// Bottom panel only: the ⌘J toggle action behind the trailing button.
    var onToggle: (() -> Void)?

    @State private var dragStartHeight: CGFloat?
    // Tab reordering: the tab itself follows the pointer horizontally while
    // its neighbors flow around it.
    @State private var draggingPaneId: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragAdjustment: CGFloat = 0
    /// The dragged tab has escaped this bar vertically and is riding the
    /// cross-group ghost; its in-strip body dims and reordering pauses.
    @State private var isCrossDragging = false
    /// Chrome-style close behavior: closing a tab freezes tab widths (the
    /// remaining tabs just slide over, keeping the next ✕ under the pointer)
    /// until the pointer leaves the strip, then widths relax to fit.
    @State private var frozenTabWidth: CGFloat?
    /// The strip's own scroll position while overflowing (NSTabBar model:
    /// the bar manages its scroll itself and folds off-viewport tabs into
    /// edge stacks rather than hiding them).
    @State private var scrollOffset: CGFloat = 0
    /// The strip's frame in window coordinates and its current scroll range,
    /// kept for the scroll-wheel monitor below (the tabs are SwiftUI
    /// content, so wheel events never reach a backing NSView reliably — a
    /// local event monitor gated by this frame handles them instead).
    @State private var stripFrame: CGRect = .zero
    @State private var stripMaxScroll: CGFloat = 0
    @State private var scrollMonitor: Any?
    /// Identity ledger for spotting freshly inserted tabs DURING body
    /// evaluation (plain class — reads are legal mid-body and don't
    /// invalidate). See stripBody's `isAppearing`.
    @State private var appearanceLedger = TabAppearanceLedger()
    /// Bumped (inside withAnimation) to release a new tab's expansion.
    @State private var appearanceTick = 0

    /// Bar heights by placement: the TOP bar's tabs are window chrome
    /// (36pt track in a 40pt row); the default tab bar (bottom panel) is
    /// more compact — 28pt track in a 32pt row.
    var barHeight: CGFloat { isBottomPanel ? 32 : 40 }
    private var trackHeight: CGFloat { isBottomPanel ? 28 : 36 }
    /// Minimum usable tab width. Below this the strip stops shrinking tabs
    /// and switches to scrolling with edge stacking (NSTabBar model).
    private static let minTabWidth: CGFloat = 100
    /// The visible sliver width of a stacked (folded) tab at the strip edge.
    private static let stackSliver: CGFloat = 14
    /// At most this many slivers fan out per edge; deeper tabs fold fully
    /// under the last sliver.
    private static let maxStackSlivers = 4
    /// No gap between slots — native tab bars (Terminal, Safari) divide the
    /// full strip into equal touching segments, separated by hairlines drawn
    /// inside the tabs; each capsule insets itself within its slot.
    private static let tabSpacing: CGFloat = 0
    /// One shared motion for every tab layout change (add/close/reorder
    /// width redistribution, snap-backs) so the strip moves as one system.
    static let tabMotion: Animation = .snappy(duration: 0.18)

    private var isBottomPanel: Bool { group.placement == .bottom }

    var body: some View {
        HStack(spacing: 8) {
            tabsArea
            if isBottomPanel {
                toggleButton
            }
        }
        // Center bar: the track's LEADING indent (header padding 10 + 8
        // here = 18) matches its trailing gap to the + button (10 here +
        // header spacing 8 = 18), so the strip reads evenly inset between
        // its neighbors. The bottom bar keeps its symmetric inset.
        .padding(.leading, isBottomPanel ? 10 : 8)
        .padding(.trailing, 10)
        .frame(height: barHeight)
        // Breathing room between the panel's top edge (divider/resize
        // handle) and the tab row.
        .padding(.top, isBottomPanel ? 6 : 0)
        .frame(maxWidth: .infinity)
        // Bottom panel chrome only. The center bar lives inside the window's
        // top bar (its host draws the band surface and boundary line), so it
        // paints no surface of its own — its tabs sit directly on the
        // toolbar band. The bottom bar paints the pane surface itself, with
        // no boundary line below, so the tabs read as part of the terminal
        // section they control.
        .background {
            if isBottomPanel {
                theme.paneBackground
            }
        }
        // The window hides its titlebar and the header rows are ordinary
        // content (see WindowChrome.swift), but the strip can sit inside the
        // residual titlebar region at the window's top edge. This backing
        // NSView opts the strip's rect out of AppKit's remaining window-move
        // paths so drags stay tab drags.
        .background(WindowDragBlocker())
        // Only the bottom bar separates from the chat above with a divider,
        // and only its top edge is the resize handle (showing the resize
        // cursor); the rest of the bar keeps the default cursor.
        .overlay(alignment: .top) {
            if isBottomPanel {
                Divider()
            }
        }
        .overlay(alignment: .top) {
            if isBottomPanel {
                resizeHandle
            }
        }
        .overlay(alignment: .topLeading) { dropIndicator }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            dragCoordinator?.updateBarFrame(frame, for: group.placement)
        }
        .onAppear {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
                handleStripScroll(event)
            }
        }
        .onDisappear {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
            }
            scrollMonitor = nil
            // The bottom bar unmounts when the panel closes; a stale frame
            // must not keep catching drops.
            dragCoordinator?.clearGeometry(for: group.placement)
        }
    }

    /// Trackpad/wheel scrolling of the strip while it overflows (the strip
    /// owns its scroll; NSTabBar model). Vertical deltas map to horizontal
    /// like native horizontal strips. Delivered via a local event monitor
    /// gated by the strip's frame — the tabs are SwiftUI content, so wheel
    /// events don't reliably reach any backing NSView of ours.
    private func handleStripScroll(_ event: NSEvent) -> NSEvent? {
        guard stripMaxScroll > 0,
              let window = event.window,
              window.isKeyWindow
        else { return event }
        // SwiftUI's global space is top-left based; event locations are
        // bottom-left based.
        let location = CGPoint(
            x: event.locationInWindow.x,
            y: window.frame.height - event.locationInWindow.y
        )
        guard stripFrame.contains(location) else { return event }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let delta = abs(dx) >= abs(dy) ? dx : dy
        guard delta != 0 else { return event }
        scrollOffset = min(max(min(scrollOffset, stripMaxScroll) - delta, 0), stripMaxScroll)
        return nil
    }

    // MARK: - Tabs

    private var tabsArea: some View {
        GeometryReader { geometry in
            // The bottom bar hosts its own +; the center bar's + lives with
            // the window's other trailing icon buttons (host header), so its
            // strip gets the full width.
            let reserved: CGFloat = isBottomPanel ? 26 + 4 : 0
            let available = max(geometry.size.width - reserved, Self.minTabWidth)
            let count = max(group.state.panes.count, 1)
            // Native tab bars divide the whole strip into equal segments
            // down to a usable minimum; past that the strip scrolls and
            // off-viewport tabs fold into edge stacks (NSTabBar model:
            // `_buttonWidthForNumberOfButtons…` + `_calculateStackingRegions`).
            let fitted = available / CGFloat(count)
            let isOverflowing = fitted < Self.minTabWidth
            let tabWidth = isOverflowing
                ? Self.minTabWidth
                : (frozenTabWidth.map { min($0, available) } ?? fitted)
            let slotWidth = tabWidth + Self.tabSpacing
            let maxScroll = max(0, CGFloat(count) * slotWidth - available)
            let offset = min(max(scrollOffset, 0), maxScroll)
            let selectedIndex = group.state.panes.firstIndex {
                $0.id == group.state.selectedPaneId
            }
            let slots = Self.stripSlots(
                count: count,
                slotWidth: slotWidth,
                available: available,
                offset: offset,
                selected: selectedIndex
            )

            // Single-tab progressive disclosure (Safari model), TOP BAR
            // ONLY: the tab dressing collapses to a plain title while the +
            // stays put in the chrome; the strip materializes on tab #2 — or
            // the moment a cross-group drag starts, as a live drop hint.
            // The bottom panel always shows its tab bar.
            let isCollapsed = !isBottomPanel
                && group.state.panes.count == 1
                && dragCoordinator?.active == nil

            // The strip (and its track) is FIXED width — closing tabs with
            // frozen widths just slides the remainder left, leaving empty
            // track until the pointer exits and widths relax to refill.
            HStack(spacing: 4) {
                stripContent(
                    isCollapsed: isCollapsed,
                    slots: slots,
                    tabWidth: tabWidth,
                    slotWidth: slotWidth,
                    available: available
                )
                    // Pointer left the strip: relax frozen widths to refit.
                    .onHover { hovering in
                        guard !hovering, frozenTabWidth != nil else { return }
                        withAnimation(Self.tabMotion) { frozenTabWidth = nil }
                    }
                    // The recessed track holding all tabs (native window tab
                    // bars): a slightly darkened well the tab capsules sit
                    // inside with even breathing room on every side. Fades
                    // away with the tabs in single-tab (collapsed) mode.
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(
                                isCollapsed ? 0 : (colorScheme == .dark ? 0.22 : 0.06)
                            ))
                            .frame(height: trackHeight)
                    )
                    .animation(Self.tabMotion, value: isCollapsed)
                    // Cross-group drop math needs the strip's leading edge
                    // and slot metrics; the scroll monitor needs the frame
                    // and range.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        stripFrame = frame
                        stripMaxScroll = maxScroll
                        dragCoordinator?.updateStrip(
                            minX: frame.minX,
                            slotWidth: slotWidth,
                            paneCount: group.state.panes.count,
                            for: group.placement
                        )
                    }

                if isBottomPanel {
                    addPaneButton
                }

                Spacer(minLength: 0)
            }
            // One trigger: the id list changes on every add/close/reorder,
            // driving the width redistribution and slide in a single pass.
            .animation(Self.tabMotion, value: group.state.panes.map(\.id))
            // The selection never stacks: scroll it clear of the edge folds
            // (NSTabBar's `_scrollToButtonAtIndex:canScrollSelectedButton:`)
            // on every path that could fold it — selection changes, reorders
            // (id order changes), drag end, and strip resizes.
            .onChange(of: group.state.selectedPaneId, initial: true) { _, _ in
                scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
            }
            .onChange(of: group.state.panes.map(\.id)) { _, _ in
                guard draggingPaneId == nil else { return }
                scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
            }
            .onChange(of: draggingPaneId) { _, dragging in
                guard dragging == nil else { return }
                scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
            }
            // New-tab expansion release: the insertion commit rendered the
            // tab tiny at its final slot (fully un-animated); flip it to
            // full scale a tick later with an explicit animation so it
            // grows strictly in place.
            .onChange(of: group.state.panes.map(\.id)) { _, newIds in
                let ledger = appearanceLedger
                let current = Set(newIds)
                guard ledger.seeded else {
                    ledger.knownIds = current
                    ledger.seeded = true
                    return
                }
                let added = current.subtracting(ledger.knownIds)
                ledger.knownIds.formIntersection(current)
                guard !added.isEmpty else { return }
                DispatchQueue.main.async {
                    ledger.knownIds.formUnion(added)
                    withAnimation(Self.tabMotion) { appearanceTick += 1 }
                }
            }
            .onAppear {
                appearanceLedger.knownIds = Set(group.state.panes.map(\.id))
                appearanceLedger.seeded = true
            }
            .onChange(of: geometry.size.width) { _, _ in
                scrollSelectionIntoView(count: count, slotWidth: slotWidth, available: available)
            }
            .onChange(of: isOverflowing) { _, overflowing in
                if !overflowing, scrollOffset != 0 {
                    scrollOffset = 0
                }
            }
        }
        .frame(height: barHeight)
    }

    /// Single-tab progressive disclosure (Safari model): with one tab and no
    /// cross-group drag in flight, the tab dressing collapses to a plain
    /// title while the + stays put in the chrome. The strip re-materializes
    /// the moment tab #2 exists — or the moment a tear-out drag starts
    /// anywhere, so the track doubles as a live drop hint.
    @ViewBuilder
    private func stripContent(
        isCollapsed: Bool,
        slots: [(x: CGFloat, width: CGFloat)],
        tabWidth: CGFloat,
        slotWidth: CGFloat,
        available: CGFloat
    ) -> some View {
        ZStack {
            if isCollapsed, let pane = group.state.panes.first {
                collapsedTitle(for: pane, slotWidth: slotWidth)
                    .transition(.opacity)
            } else {
                stripBody(slots: slots, tabWidth: tabWidth, slotWidth: slotWidth)
                    .frame(width: available, height: barHeight, alignment: .topLeading)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(width: available, height: barHeight)
    }

    /// The lone tab rendered as a quiet title (top bar only — the bottom
    /// panel always shows its tab bar). The inert title area doubles as
    /// window-drag space; the only possible single tab here is the
    /// unclosable chat.
    private func collapsedTitle(for pane: PaneDescriptorState, slotWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Drag regions claim drags geometrically, so the whole title
            // area moves the window even under the (inert) text.
            WindowDragGap()
            // Shared page-title style; this strip sits 18 from the
            // column's leading edge (header 10 + bar 8), so the
            // remainder lands the title at WindowChrome.pageTitleIndent.
            HeaderPageTitle(text: pane.kind == .chat ? (chatTabTitle ?? pane.name) : pane.name)
                .padding(.horizontal, WindowChrome.pageTitleIndent - 18)
        }
    }

    private func stripBody(
        slots: [(x: CGFloat, width: CGFloat)], tabWidth: CGFloat, slotWidth: CGFloat
    ) -> some View {
        let panes = group.state.panes
        return ZStack(alignment: .topLeading) {
            // Re-rendered when a new tab's expansion is released (below).
            let _ = appearanceTick
            ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                        let slot = index < slots.count ? slots[index] : (x: 0, width: tabWidth)
                        // Fresh this commit: render at ~zero width AT its
                        // final slot with ALL animation disabled, then a
                        // next-tick withAnimation expands it in place. The
                        // transition system is deliberately not used here —
                        // inserted views inherit the ambient animation for
                        // their initial geometry and fly in across the strip.
                        let isAppearing = appearanceLedger.seeded
                            && !appearanceLedger.knownIds.contains(pane.id)
                        PaneTab(
                            name: pane.kind == .chat ? (chatTabTitle ?? pane.name) : pane.name,
                            kind: pane.kind,
                            isAgentOwned: pane.attachOnly,
                            isSelected: pane.id == group.state.selectedPaneId,
                            isDragging: draggingPaneId == pane.id,
                            width: slot.width,
                            // The chat pane has no ✕ (not closable); closable
                            // tabs reveal theirs on hover, in the glyph's
                            // place (Safari behavior).
                            canClose: pane.isClosable,
                            // Hairline between adjacent tabs, hidden around
                            // the selected capsule (native tab bars).
                            showsTrailingSeparator: index < panes.count - 1
                                && pane.id != group.state.selectedPaneId
                                && panes[index + 1].id != group.state.selectedPaneId
                                && draggingPaneId == nil,
                            // Top-bar tabs live in the chrome layer (glass
                            // selection); header tabs live in the content
                            // layer (quiet fill).
                            style: isBottomPanel ? .header : .toolbar,
                            // ⌘N hint, shown while this bar is the
                            // shortcuts' target (⌘1-9 reach the first nine).
                            shortcutHint: showsShortcutHints && index < 9
                                ? "⌘\(index + 1)" : nil,
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
                        // Folded slivers clip their content at the slot edge
                        // (native stacked tabs show only their leading edge).
                        .clipped()
                        // The manual in-place expansion (see isAppearing):
                        // anchored TRAILING — the new tab's right edge stays
                        // planted while its left edge sweeps left, chasing
                        // the neighbors it pushes out of the way.
                        .scaleEffect(x: isAppearing ? 0.01 : 1, y: 1, anchor: .trailing)
                        .offset(x: slot.x + (draggingPaneId == pane.id ? dragOffset : 0))
                        // Dim the in-strip body while its ghost rides the
                        // pointer to another bar.
                        .opacity(draggingPaneId == pane.id && isCrossDragging ? 0.3 : 1)
                        // Dragged above all; the selected above the tabs that
                        // fold under it when it pins at a strip edge.
                        .zIndex(
                            draggingPaneId == pane.id
                                ? 2
                                : (pane.id == group.state.selectedPaneId ? 1 : 0)
                        )
                        // The dragged tab tracks the pointer directly (no
                        // animated slot shifts), and a freshly inserted tab
                        // commits its initial tiny-at-final-slot state with
                        // NOTHING animated — the expansion is released
                        // explicitly a tick later.
                        .transaction { transaction in
                            if draggingPaneId == pane.id || isAppearing {
                                transaction.animation = nil
                            }
                        }
                        // High priority so nothing steals the drag
                        // mid-reorder; taps still pass through via the 3pt
                        // minimum distance.
                        .highPriorityGesture(reorderGesture(for: pane.id, slotWidth: slotWidth))
                        // Closing tabs fade out; insertion is fully manual.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .frame(height: barHeight, alignment: .topLeading)
    }

    /// The NSTabBar layout, reconstructed: each tab's natural position is its
    /// slot minus the scroll offset, clamped into per-edge stacking bounds so
    /// off-viewport tabs fold into slivers at the edges instead of vanishing.
    /// A tab's width is the gap to its neighbor's position — folded tabs
    /// become their sliver, visible tabs their full slot. The SELECTED tab is
    /// special (`_scrollToButtonAtIndex:canScrollSelectedButton:`): it never
    /// compresses — scrolled off-viewport it pins at the strip edge at full
    /// width, drawn above the tabs folding under it.
    private static func stripSlots(
        count: Int, slotWidth: CGFloat, available: CGFloat, offset: CGFloat, selected: Int?
    ) -> [(x: CGFloat, width: CGFloat)] {
        var xs: [CGFloat] = []
        xs.reserveCapacity(count)
        for index in 0..<count {
            let raw = CGFloat(index) * slotWidth - offset
            if index == selected {
                // Pin at the edge at full width, leaving the far-side stack
                // its sliver room: tabs ORDERED PAST the pinned edge stay
                // visible as slivers beyond it, while tabs folding TOWARD it
                // slide underneath (native behavior).
                let leftPin = Self.stackSliver * CGFloat(min(index, Self.maxStackSlivers))
                let rightPin = available - slotWidth
                    - Self.stackSliver * CGFloat(min(count - 1 - index, Self.maxStackSlivers))
                xs.append(min(max(raw, leftPin), max(leftPin, rightPin)))
            } else {
                let leftMin = Self.stackSliver * CGFloat(min(index, Self.maxStackSlivers))
                let rightCap = available - Self.stackSliver * CGFloat(min(count - index, Self.maxStackSlivers))
                xs.append(min(max(raw, leftMin), max(leftMin, rightCap)))
            }
        }
        // Tabs folding toward a pinned selected slide UNDER it, never past.
        if let selected, count > 0 {
            for index in 0..<selected {
                xs[index] = min(xs[index], xs[selected])
            }
            for index in (selected + 1)..<count {
                xs[index] = max(xs[index], xs[selected])
            }
        }
        var slots: [(x: CGFloat, width: CGFloat)] = []
        slots.reserveCapacity(count)
        for index in 0..<count {
            if index == selected {
                slots.append((x: xs[index], width: slotWidth))
                continue
            }
            let next = index + 1 < count ? xs[index + 1] : available
            slots.append((x: xs[index], width: max(1, min(slotWidth, next - xs[index]))))
        }
        return slots
    }

    /// Scrolls so the selected tab sits fully clear of both edge stacks.
    private func scrollSelectionIntoView(count: Int, slotWidth: CGFloat, available: CGFloat) {
        guard let selectedId = group.state.selectedPaneId,
              let selected = group.state.panes.firstIndex(where: { $0.id == selectedId })
        else { return }
        let maxScroll = max(0, CGFloat(count) * slotWidth - available)
        guard maxScroll > 0 else {
            if scrollOffset != 0 { scrollOffset = 0 }
            return
        }
        let leftReserve = Self.stackSliver * CGFloat(min(selected, Self.maxStackSlivers))
        let rightReserve = Self.stackSliver * CGFloat(min(count - 1 - selected, Self.maxStackSlivers))
        let upper = CGFloat(selected) * slotWidth - leftReserve
        let lower = CGFloat(selected + 1) * slotWidth - available + rightReserve
        var target = min(max(scrollOffset, lower), upper)
        target = min(max(target, 0), maxScroll)
        guard abs(target - scrollOffset) > 0.5 else { return }
        withAnimation(Self.tabMotion) { scrollOffset = target }
    }

    /// Drag-to-reorder (and tear-out): the tab is glued to the pointer
    /// horizontally (offset = pointer translation minus the slots it has
    /// already swapped across); crossing half a neighbor's slot swaps
    /// positions and only the neighbors animate. Measured in the window's
    /// global space — stable across slot swaps, and shared with the drop
    /// geometry so a closable tab dragged out of the bar can travel to the
    /// session's other pane group.
    private func reorderGesture(for paneId: UUID, slotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
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

                // Tear-out: once the pointer escapes the bar vertically, the
                // drag belongs to the cross-group coordinator (ghost tab +
                // drop caret) until it comes back.
                if let dragCoordinator,
                   let descriptor = group.state.panes.first(where: { $0.id == paneId }),
                   descriptor.isClosable,
                   dragCoordinator.escapesSourceBar(value.location, source: group.placement) {
                    isCrossDragging = true
                    dragCoordinator.dragUpdated(
                        paneId: paneId,
                        source: group.placement,
                        name: descriptor.name,
                        isAgentOwned: descriptor.attachOnly,
                        location: value.location
                    )
                    return
                }
                if isCrossDragging {
                    isCrossDragging = false
                    dragCoordinator?.dragCancelled()
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
                if isCrossDragging {
                    isCrossDragging = false
                    if dragCoordinator?.dragEnded() == true {
                        // The pane moved to the other group; its tab is gone
                        // from this strip, nothing to snap back.
                        draggingPaneId = nil
                        dragOffset = 0
                        dragAdjustment = 0
                        return
                    }
                }
                withAnimation(Self.tabMotion) {
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

    /// The insertion caret shown while a tab from the other group hovers over
    /// this bar, at the slot where a drop would land it.
    @ViewBuilder
    private var dropIndicator: some View {
        if let dragCoordinator,
           let drag = dragCoordinator.active,
           drag.target == group.placement,
           drag.source != group.placement,
           let bar = dragCoordinator.barGeometry(for: group.placement) {
            RoundedRectangle(cornerRadius: 1)
                .fill(theme.accent)
                .frame(width: 2, height: 16)
                .offset(
                    x: bar.stripMinX - bar.barFrame.minX
                        + CGFloat(drag.insertionIndex) * bar.slotWidth - 1,
                    y: (barHeight - 16) / 2
                )
                .allowsHitTesting(false)
        }
    }

    private var addPaneButton: some View {
        Button {
            frozenTabWidth = nil
            group.addTerminalPane()
            // Defer until SwiftUI has mounted the new pane's view.
            DispatchQueue.main.async { group.focusSelectedPane() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("New terminal")
        .accessibilityLabel("New terminal")
    }

    private var toggleButton: some View {
        Button {
            onToggle?()
        } label: {
            Image(systemName: "rectangle.bottomthird.inset.filled")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Toggle bottom panel (⌘J)")
        .accessibilityLabel("Toggle bottom panel")
        .accessibilityHint("Keyboard shortcut: Command-J")
    }

    // MARK: - Resize

    /// A thin strip on the bottom bar's top edge: the only place that shows
    /// the resize cursor and accepts the resize drag (drag up = taller).
    private var resizeHandle: some View {
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


/// An invisible backing view that opts the tab strip's rect out of AppKit's
/// window-move paths, so drags on tabs are only ever tab drags. Two hooks,
/// covering both mechanisms a hidden-titlebar window still has:
///
/// - `mouseDownCanMoveWindow == false`: the classic move-by-background /
///   titlebar-region probe, consulted for content under a transparent
///   titlebar.
/// - `_opaqueRectForWindowMoveWhenInTitlebar`: the region mechanism that is
///   independent of both `mouseDownCanMoveWindow` and `NSWindow.isMovable`
///   (measured). The same private-but-stable hook Zed ships in production
///   (gpui_macos/window.rs) to mark app-owned titlebar content; it also opts
///   out of the titlebar double-click disambiguation delay.
private struct WindowDragBlocker: NSViewRepresentable {
    final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        /// Overrides AppKit's private region probe; matching the selector is
        /// enough for the runtime to dispatch here.
        @objc(_opaqueRectForWindowMoveWhenInTitlebar)
        private func opaqueRectForWindowMoveWhenInTitlebar() -> NSRect {
            bounds
        }
    }

    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Where a tab bar lives, which sets the selected tab's material per the
/// Liquid Glass guidance: chrome-layer (toolbar) selections are glass
/// capsules beside the window's other glass controls; content-layer (pane
/// header) selections are quiet opaque fills.
enum PaneTabStyle {
    case toolbar
    case header
}

/// One tab: an equal-width segment with its content (glyph + name) centered,
/// native-tab-bar style (Terminal, Safari). The selected tab is a stroked
/// capsule inset within its slot; unselected neighbors are divided by
/// hairlines and show the same capsule as a quiet tint on hover — nothing
/// changes shape on click. Hovering a closable tab swaps its glyph for the ✕
/// (Safari behavior), so nothing shifts. The hit target is the full slot.
/// Identity ledger backing the manual new-tab expansion (see stripBody).
private final class TabAppearanceLedger {
    var knownIds: Set<UUID> = []
    var seeded = false
}

private struct PaneTab: View {
    @Environment(\.theme) private var theme
    let name: String
    let kind: PaneKind
    /// Agent-owned background terminals get a server-rack glyph so ownership
    /// is obvious next to the user's own shells (which get a terminal glyph).
    let isAgentOwned: Bool
    let isSelected: Bool
    let isDragging: Bool
    let width: CGFloat
    let canClose: Bool
    let showsTrailingSeparator: Bool
    let style: PaneTabStyle
    /// "⌘N", shown at the trailing edge while this bar is the target of the
    /// tab shortcuts (native window tab bars).
    let shortcutHint: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @State private var isCloseHovered = false

    /// Width thresholds, NSTabButton-style (`setButtonWidthForTitleLayout:`):
    /// the bar hands each tab its width and the tab decides what fits — the
    /// hint drops first, then the hover ✕, then the glyph; the title
    /// truncates before ever colliding with any of them. Folded slivers
    /// lead-align so their visible edge shows the title's start (native).
    private var showsHint: Bool { shortcutHint != nil && width >= 90 }
    private var fitsCloseButton: Bool { width >= 64 }
    private var showsIcon: Bool { width >= 48 }
    private var isSliver: Bool { width < 48 }

    /// Symmetric side reserve keeping the centered title clear of the edge
    /// adornment zones (leading ✕ / trailing ⌘N). PERMANENTLY reserved based
    /// on width alone, never on hover/focus — the native bar fixes each
    /// button's title layout width up front (`setButtonWidthForTitleLayout:`)
    /// so adornments appearing only toggle visibility, never move content.
    private var contentSideReserve: CGFloat {
        if width >= 90 { return 30 }
        if canClose && fitsCloseButton { return 24 }
        return 0
    }

    /// The tab content's horizontal inset within its capsule.
    private var contentPadding: CGFloat { style == .header ? 8 : 10 }
    /// The capsule's inset within the tab's slot — used on ALL sides against
    /// the track (horizontal within the slot, vertical via
    /// `trackHeight - capsuleHeight`), so the breathing room reads even.
    private var capsuleInset: CGFloat { style == .header ? 3 : 4 }
    /// The recessed track's height, centered in the bar: taller for the top
    /// bar's chrome tabs, compact for the default (bottom panel) bar.
    private var trackHeight: CGFloat { style == .header ? 28 : 36 }
    /// The capsule's visual height: the track minus an even inset on both
    /// sides. The remaining bar height stays part of the hit target.
    private var capsuleHeight: CGFloat { trackHeight - 2 * capsuleInset }
    /// The full bar row this tab's hit target spans.
    private var barHeight: CGFloat { style == .header ? 32 : 40 }

    private var iconName: String {
        switch kind {
        case .chat: "text.bubble"
        case .terminal: isAgentOwned ? "server.rack" : "terminal"
        }
    }

    private var iconHelp: String {
        switch kind {
        case .chat: "Chat"
        case .terminal: isAgentOwned ? "Agent background process" : "Terminal"
        }
    }

    /// System-theme toolbar tabs select with Liquid Glass; themed palettes
    /// (opaque surfaces everywhere) and content-layer headers use the quiet
    /// selected fill instead.
    private var usesGlassSelection: Bool {
        style == .toolbar && theme.isSystem
    }

    var body: some View {
        capsuleContent
            .background {
                Group {
                    if isSelected && usesGlassSelection {
                        Color.clear
                            .glassEffect(.regular, in: Capsule())
                            // The glass system's DEFAULT transition is a
                            // matched-geometry morph: the platter of a
                            // disappearing glass travels to any appearing
                            // one. Selection must swap in place instead.
                            .glassEffectTransition(.identity)
                            .overlay(Capsule().strokeBorder(theme.border))
                    } else if isSelected {
                        Capsule()
                            .fill(theme.rowSelectedBackground)
                            .overlay(Capsule().strokeBorder(theme.border))
                    } else {
                        Capsule().fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                    }
                }
                // Native tab bars swap the selection highlight INSTANTLY —
                // no crossfade, and never a capsule traveling between the
                // old and new selection. Only tab positions/widths animate.
                .transaction { $0.animation = nil }
            }
        // Hover reveals the ✕ pinned at the tab's leading edge (native
        // window tab bars); the glyph + name stay centered.
        .overlay(alignment: .leading) {
            if canClose && isHovered && fitsCloseButton {
                closeButton
                    .padding(.leading, capsuleInset + 5)
                    .transition(.opacity)
            }
        }
        // The ⌘N shortcut hint at the trailing edge, dropped when the tab is
        // too narrow for it.
        .overlay(alignment: .trailing) {
            if showsHint, let shortcutHint {
                Text(shortcutHint)
                    .font(.caption)
                    // Same ink as the tab name in both states.
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.trailing, capsuleInset + 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showsHint)
        // Hover states ease rather than pop: the tint fill and the ✕ share
        // one short fade.
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .padding(.horizontal, capsuleInset)
        .frame(width: width, height: barHeight)
        // The boundary hairline dividing unselected neighbors (native tab
        // bars hide it around the selected capsule). Always mounted, faded —
        // conditional insertion popped abruptly on selection changes.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1, height: 14)
                .offset(x: 0.5)
                .opacity(showsTrailingSeparator ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: showsTrailingSeparator)
        }
        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 3, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private var capsuleContent: some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    // Same ink as the label in both states.
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .help(iconHelp)
            }
            Text(name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.horizontal, isSliver ? 5 : contentPadding)
        // Reserve the edge adornments' zones on BOTH sides while they show,
        // so the centered title truncates before reaching them (and stays
        // truly centered).
        .padding(.horizontal, contentSideReserve)
        // Folded slivers show the leading edge of their title (native
        // stacked tabs); everything else centers.
        .frame(maxWidth: .infinity, alignment: isSliver ? .leading : .center)
        .frame(height: capsuleHeight)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(isCloseHovered ? .primary : .secondary)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isCloseHovered ? 0.14 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .help("Close terminal")
        .accessibilityLabel("Close terminal")
    }
}

/// The selected pane's content, mounted only while the group is open. Panes
/// cache their expensive backing state (the terminal caches its NSView), so
/// switching tabs restores rather than rebuilds. The chat pane's content is
/// NOT rendered here — SessionScreen owns it (kept alive across tab switches).
struct PaneGroupContent: View {
    var group: PaneGroupModel

    var body: some View {
        if let pane = group.selectedPane {
            pane.makeView()
                .id(pane.id)
        }
    }
}
