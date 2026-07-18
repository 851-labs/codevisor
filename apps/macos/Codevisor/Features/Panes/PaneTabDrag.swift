//  Cross-group tab dragging: move a tab between ANY of a workspace's pane
//  groups — bottom panel, any center leaf's bar — or drop it on a group's
//  CONTENT. Content drops SPLIT toward the nearest edge (always previewed,
//  no dead center zone); holding ⇧ switches the drop to "join this group"
//  instead (VS Code's modifier), hiding the preview. Hovering a tab bar
//  never shows a split preview — the bar wins and shows its insertion
//  caret.
//
//  The session container owns one coordinator. Each bar and each center
//  leaf's content reports its geometry (window global space); a tab drag
//  that escapes its own bar forwards updates here; the coordinator resolves
//  the hovered destination; the screen renders the floating ghost, bars
//  render insertion carets, and content renders the translucent region
//  preview. Within-bar reordering never touches the coordinator.

import Foundation
import AppKit
import SwiftUI
import CodevisorCore

/// Identifies a drop-capable group: the ⌘J bottom panel or a center-tree
/// leaf.
enum PaneGroupRef: Hashable {
    case bottom
    case centerLeaf(UUID)

    var leafId: UUID? {
        if case let .centerLeaf(id) = self { return id }
        return nil
    }
}

/// What a drop will do, resolved live while the pointer moves.
enum PaneDropResolution: Equatable {
    /// Insert into a group's tab strip at an index.
    case bar(PaneGroupRef, index: Int)
    /// Append into a group (content-center drop).
    case join(PaneGroupRef)
    /// Split a center leaf on an edge; the dragged pane forms the new group.
    case split(leafId: UUID, edge: SplitEdge)
}

@MainActor
@Observable
final class PaneTabDragCoordinator {
    /// A bar's live geometry, in the window's global coordinate space.
    struct BarGeometry {
        var barFrame: CGRect = .zero
        /// The tab strip's leading edge (drives insertion-index math).
        var stripMinX: CGFloat = 0
        var slotWidth: CGFloat = 100
        var paneCount: Int = 0
    }

    struct ActiveDrag {
        let paneId: UUID
        let source: PaneGroupRef
        let name: String
        let kind: PaneKind
        let isAgentOwned: Bool
        /// The source group's LIVE pane count at drag time. Deliberately not
        /// read from the bar-geometry cache: that only refreshes when the
        /// strip's FRAME changes, and adding a tab doesn't move the frame —
        /// a stale count silently vetoed self-splits.
        let sourcePaneCount: Int
        /// Whether the pane may drop into the BOTTOM panel (terminals only
        /// live there; a New Tab placeholder's picker page can't render in
        /// it). Center groups accept every movable pane.
        let allowsBottomDrop: Bool
        var location: CGPoint
        /// The resolved drop (nil = no valid target under the pointer).
        var resolution: PaneDropResolution?
    }

    /// How far beyond a bar's frame the pointer still counts as "over" it.
    private static let dropSlop: CGFloat = 12
    /// The smallest a split child may be, per axis (shared with the branch
    /// view's divider clamps): edges whose split would produce panes below
    /// these aren't offered at all.
    static let minChildWidth: CGFloat = 320
    static let minChildHeight: CGFloat = 280

    private(set) var active: ActiveDrag?
    /// ⇧ held during the drag: content drops JOIN the hovered group instead
    /// of splitting it (and the split preview hides). Tracked live — a
    /// flags monitor re-resolves while the pointer is stationary.
    private(set) var joinModifierHeld = false
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var bars: [PaneGroupRef: BarGeometry] = [:]
    @ObservationIgnored private var contentFrames: [UUID: CGRect] = [:]
    /// Wired by the session container: performs the model/tree-level move.
    @ObservationIgnored var onResolve: ((UUID, PaneGroupRef, PaneDropResolution) -> Void)?

    // MARK: - Geometry registration

    func updateBarFrame(_ frame: CGRect, for ref: PaneGroupRef) {
        bars[ref, default: BarGeometry()].barFrame = frame
    }

    func updateStrip(minX: CGFloat, slotWidth: CGFloat, paneCount: Int, for ref: PaneGroupRef) {
        var bar = bars[ref, default: BarGeometry()]
        bar.stripMinX = minX
        bar.slotWidth = slotWidth
        bar.paneCount = paneCount
        bars[ref] = bar
    }

    /// Bars unmount (the panel closes; a leaf dissolves); stale frames must
    /// not keep accepting drops.
    func clearGeometry(for ref: PaneGroupRef) {
        bars[ref] = nil
    }

    func barGeometry(for ref: PaneGroupRef) -> BarGeometry? {
        bars[ref]
    }

    func updateContentFrame(_ frame: CGRect, leafId: UUID) {
        contentFrames[leafId] = frame
    }

    func clearContentFrame(leafId: UUID) {
        contentFrames[leafId] = nil
    }

    // MARK: - Drag lifecycle

    /// Whether `location` has escaped the source bar (vertically far enough
    /// that this drag reads as a tear-out rather than a reorder).
    func escapesSourceBar(_ location: CGPoint, source: PaneGroupRef) -> Bool {
        guard let bar = bars[source] else { return false }
        return !bar.barFrame.insetBy(dx: 0, dy: -Self.dropSlop).contains(location)
    }

    func dragUpdated(
        paneId: UUID,
        source: PaneGroupRef,
        name: String,
        kind: PaneKind,
        isAgentOwned: Bool,
        sourcePaneCount: Int,
        allowsBottomDrop: Bool,
        location: CGPoint
    ) {
        if flagsMonitor == nil {
            startFlagsMonitor()
        }
        joinModifierHeld = NSEvent.modifierFlags.contains(.shift)
        active = ActiveDrag(
            paneId: paneId,
            source: source,
            name: name,
            kind: kind,
            isAgentOwned: isAgentOwned,
            sourcePaneCount: sourcePaneCount,
            allowsBottomDrop: allowsBottomDrop,
            location: location,
            resolution: resolve(
                location,
                source: source,
                sourcePaneCount: sourcePaneCount,
                allowsBottomDrop: allowsBottomDrop
            )
        )
    }

    /// Toggling ⇧ must re-resolve even while the pointer is stationary (no
    /// drag update fires) — the preview swaps live, like VS Code's.
    private func startFlagsMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.joinModifierHeld = event.modifierFlags.contains(.shift)
                if var drag = self.active {
                    drag.resolution = self.resolve(
                        drag.location,
                        source: drag.source,
                        sourcePaneCount: drag.sourcePaneCount,
                        allowsBottomDrop: drag.allowsBottomDrop
                    )
                    self.active = drag
                }
            }
            return event
        }
    }

    private func stopFlagsMonitor() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        flagsMonitor = nil
    }

    /// Ends the drag; performs the resolved move. Returns true when a move
    /// happened (the source bar skips its snap-back animation for a tab
    /// that just left).
    func dragEnded() -> Bool {
        defer {
            active = nil
            stopFlagsMonitor()
        }
        guard let drag = active, let resolution = drag.resolution else { return false }
        onResolve?(drag.paneId, drag.source, resolution)
        return true
    }

    func dragCancelled() {
        active = nil
        stopFlagsMonitor()
    }

    // MARK: - Rendering queries

    /// The insertion caret a bar should render (its ref's resolved index).
    func insertionCaret(for ref: PaneGroupRef) -> Int? {
        guard let drag = active, case let .bar(target, index) = drag.resolution,
              target == ref else { return nil }
        return index
    }

    /// The split-region preview a leaf should render (the half the new
    /// group would occupy), nil when the leaf isn't a split target. Joins
    /// (⇧ held) deliberately render NO overlay — the hidden preview IS the
    /// "drop in group" signal (VS Code's modifier behavior).
    func contentPreview(for leafId: UUID) -> SplitEdge? {
        guard let drag = active,
              case let .split(id, edge) = drag.resolution,
              id == leafId else { return nil }
        return edge
    }

    // MARK: - Resolution

    private func resolve(
        _ location: CGPoint,
        source: PaneGroupRef,
        sourcePaneCount: Int,
        allowsBottomDrop: Bool
    ) -> PaneDropResolution? {
        // Bars win over content (they overlap content edges visually).
        for (ref, bar) in bars where ref != source {
            if ref == .bottom && !allowsBottomDrop { continue }
            if bar.barFrame.insetBy(dx: 0, dy: -Self.dropSlop).contains(location) {
                return .bar(ref, index: insertionIndex(for: location.x, in: bar))
            }
        }
        for (leafId, frame) in contentFrames where frame.contains(location) {
            let ref = PaneGroupRef.centerLeaf(leafId)
            // ⇧: drop INTO the hovered group instead of splitting it.
            if joinModifierHeld {
                // Joining your own group is a no-op.
                guard ref != source else { return nil }
                return .join(ref)
            }
            // Splitting a single-pane group with its own pane is a no-op
            // shuffle; suppress it. (Multi-pane groups split themselves
            // freely — the dragged pane forms the new neighbor.)
            if ref == source, sourcePaneCount <= 1 { return nil }
            guard let edge = nearestEdge(in: frame, location: location) else { return nil }
            return .split(leafId: leafId, edge: edge)
        }
        return nil
    }

    /// Content drops split toward the NEAREST edge — no dead middle zone
    /// (⇧ covers "into the group") — but only edges whose split would FIT:
    /// splitting halves the region on that axis, so an axis whose halves
    /// would fall below the minimum pane size isn't offered (a short panel
    /// may still offer left/right while hiding top/bottom; nothing fits →
    /// no split at all).
    private func nearestEdge(in frame: CGRect, location: CGPoint) -> SplitEdge? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let fitsHorizontal = (frame.width - 1) / 2 >= Self.minChildWidth
        let fitsVertical = (frame.height - 1) / 2 >= Self.minChildHeight
        let u = Double((location.x - frame.minX) / frame.width)
        let v = Double((location.y - frame.minY) / frame.height)
        var candidates: [(SplitEdge, Double)] = []
        if fitsHorizontal {
            candidates += [(.leading, u), (.trailing, 1 - u)]
        }
        if fitsVertical {
            candidates += [(.top, v), (.bottom, 1 - v)]
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    private func insertionIndex(for x: CGFloat, in bar: BarGeometry) -> Int {
        guard bar.slotWidth > 0 else { return bar.paneCount }
        let raw = Int(((x - bar.stripMinX) / bar.slotWidth).rounded())
        return min(max(raw, 0), bar.paneCount)
    }
}

/// Registers a center leaf's content area as a drop zone and renders the
/// translucent region preview while a drag targets it.
struct PaneDropZoneModifier: ViewModifier {
    let coordinator: PaneTabDragCoordinator?
    let leafId: UUID

    /// The last measured frame, re-pushed at every drag start:
    /// onGeometryChange only fires on CHANGES, so a registration lost to an
    /// unmount race (or cleared by a dissolve of a re-used id) would
    /// otherwise never heal — and every drop over this zone would silently
    /// resolve to nothing.
    @State private var measuredFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                measuredFrame = frame
                coordinator?.updateContentFrame(frame, leafId: leafId)
            }
            .onChange(of: coordinator?.active?.paneId) { _, active in
                if active != nil, measuredFrame != .zero {
                    coordinator?.updateContentFrame(measuredFrame, leafId: leafId)
                }
            }
            .onDisappear {
                coordinator?.clearContentFrame(leafId: leafId)
            }
            .overlay {
                if let coordinator, let edge = coordinator.contentPreview(for: leafId) {
                    PaneDropRegionPreview(edge: edge)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func paneDropZone(_ coordinator: PaneTabDragCoordinator?, leafId: UUID?) -> some View {
        modifier(PaneDropZoneModifier(coordinator: leafId == nil ? nil : coordinator, leafId: leafId ?? UUID()))
    }
}

/// The VS Code-style split preview: the half of the area the new group
/// would occupy, tinted, carrying the ⇧ escape-hatch hint. (Joins — ⇧
/// held — render nothing: the vanished preview IS the signal.)
private struct PaneDropRegionPreview: View {
    @Environment(\.theme) private var theme
    let edge: SplitEdge

    var body: some View {
        GeometryReader { geometry in
            let rect = regionRect(in: geometry.size)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.4))
                )
                .overlay {
                    Text("Hold ⇧ to drop in group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.separator))
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .animation(.snappy(duration: 0.16), value: edge)
        }
        .padding(2)
    }

    private func regionRect(in size: CGSize) -> CGRect {
        switch edge {
        case .leading:
            CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .trailing:
            CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

/// The floating tab replica that follows the pointer during a cross-group
/// drag. Rendered by the session screen in an overlay above everything, so
/// the tab can visually travel between bars (each bar clips its own tabs).
/// Matches the tab capsule; solid (popover surface) so it reads over any
/// content it crosses.
struct PaneTabDragGhost: View {
    @Environment(\.theme) private var theme
    let name: String
    var kind: PaneKind = .terminal
    let isAgentOwned: Bool

    private var iconName: String {
        switch kind {
        case .chat: "text.bubble"
        case .terminal: isAgentOwned ? "server.rack" : "terminal"
        case .newTab: "square.dashed"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(name)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            Capsule()
                .fill(theme.popoverBackground)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.separator)
        )
    }
}
