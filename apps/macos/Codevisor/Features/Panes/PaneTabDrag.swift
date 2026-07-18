//  Cross-group tab dragging: move a terminal tab between the session's two
//  pane groups (bottom panel ⇄ center group) by dragging it out of its bar
//  and dropping it on the other one.
//
//  The session screen owns one coordinator and hands it to both bars. Each
//  bar reports its geometry (in the window's global space) and forwards drag
//  updates once the pointer escapes its own bar vertically; the coordinator
//  resolves the hovered destination + insertion index, the screen renders the
//  floating ghost tab, and the destination bar renders the insertion caret.
//  Within-bar reordering never touches the coordinator.

import Foundation
import SwiftUI
import CodevisorCore

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
        let source: PaneGroupPlacement
        let name: String
        let isAgentOwned: Bool
        var location: CGPoint
        /// The bar the pointer is currently over (nil = no valid drop).
        var target: PaneGroupPlacement?
        var insertionIndex: Int = 0
    }

    /// How far beyond a bar's frame the pointer still counts as "over" it.
    private static let dropSlop: CGFloat = 12

    private(set) var active: ActiveDrag?
    @ObservationIgnored private var geometry: [PaneGroupPlacement: BarGeometry] = [:]
    /// Wired by the session screen: performs the model-level move
    /// (paneId, source, destination, insertion index).
    @ObservationIgnored var onTransfer: ((UUID, PaneGroupPlacement, PaneGroupPlacement, Int) -> Void)?

    func updateBarFrame(_ frame: CGRect, for placement: PaneGroupPlacement) {
        geometry[placement, default: BarGeometry()].barFrame = frame
    }

    func updateStrip(
        minX: CGFloat, slotWidth: CGFloat, paneCount: Int, for placement: PaneGroupPlacement
    ) {
        var bar = geometry[placement, default: BarGeometry()]
        bar.stripMinX = minX
        bar.slotWidth = slotWidth
        bar.paneCount = paneCount
        geometry[placement] = bar
    }

    /// The bottom bar unmounts when the panel closes; stale frames must not
    /// keep accepting drops.
    func clearGeometry(for placement: PaneGroupPlacement) {
        geometry[placement] = nil
    }

    func barGeometry(for placement: PaneGroupPlacement) -> BarGeometry? {
        geometry[placement]
    }

    /// Whether `location` has escaped the source bar (vertically far enough
    /// that this drag reads as a tear-out rather than a reorder).
    func escapesSourceBar(_ location: CGPoint, source: PaneGroupPlacement) -> Bool {
        guard let bar = geometry[source] else { return false }
        return !bar.barFrame.insetBy(dx: 0, dy: -Self.dropSlop).contains(location)
    }

    func dragUpdated(
        paneId: UUID,
        source: PaneGroupPlacement,
        name: String,
        isAgentOwned: Bool,
        location: CGPoint
    ) {
        let destination: PaneGroupPlacement = source == .bottom ? .center : .bottom
        var target: PaneGroupPlacement?
        var index = 0
        if let bar = geometry[destination],
           bar.barFrame.insetBy(dx: 0, dy: -Self.dropSlop).contains(location) {
            target = destination
            index = insertionIndex(for: location.x, in: bar)
        }
        active = ActiveDrag(
            paneId: paneId,
            source: source,
            name: name,
            isAgentOwned: isAgentOwned,
            location: location,
            target: target,
            insertionIndex: index
        )
    }

    /// Ends the drag; performs the transfer when over a valid destination.
    /// Returns true when a transfer happened (the source bar skips its
    /// snap-back animation for a tab that just left).
    func dragEnded() -> Bool {
        defer { active = nil }
        guard let drag = active, let target = drag.target else { return false }
        onTransfer?(drag.paneId, drag.source, target, drag.insertionIndex)
        return true
    }

    func dragCancelled() {
        active = nil
    }

    private func insertionIndex(for x: CGFloat, in bar: BarGeometry) -> Int {
        guard bar.slotWidth > 0 else { return bar.paneCount }
        let raw = Int(((x - bar.stripMinX) / bar.slotWidth).rounded())
        return min(max(raw, 0), bar.paneCount)
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
    let isAgentOwned: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isAgentOwned ? "server.rack" : "terminal")
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
