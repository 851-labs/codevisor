import CoreGraphics
import Foundation

/// One immutable visual slot captured when a workspace-tab drag begins.
///
/// The pane views animate between these slots as their persisted order
/// changes. Keeping hit testing on the captured geometry prevents those
/// animations from moving the reorder thresholds underneath the finger.
public struct WorkspaceTabGridSlot: Equatable, Sendable {
    public let index: Int
    public let frame: CGRect

    public init(index: Int, frame: CGRect) {
        self.index = index
        self.frame = frame
    }
}

/// Stable, Safari-style slot selection for the workspace tab grid.
public enum WorkspaceTabGridReorderContract {
    /// The pointer must travel slightly beyond the midpoint between the
    /// current slot and its nearest neighbor before the empty slot moves.
    /// After the move, the inverse boundary is equally far on the other side,
    /// creating a dead band that prevents rapid back-and-forth reorders.
    public static let commitProgress: CGFloat = 0.58

    /// A lifted card may stray just beyond the outer cards without suddenly
    /// losing its last valid position. Farther excursions do not reorder.
    public static let horizontalExitTolerance: CGFloat = 0.3
    public static let verticalExitTolerance: CGFloat = 0.35

    /// Resolves a new canonical slot using only geometry captured at pickup.
    /// Returns nil while the pointer remains in the current slot's hysteresis
    /// region, outside the grid, or when the measurements are unusable.
    public static func targetIndex(
        currentIndex: Int,
        point: CGPoint,
        slots: [WorkspaceTabGridSlot]
    ) -> Int? {
        let usable = slots.filter { $0.frame.isUsableGridSlot }
        guard
            let current = usable.first(where: { $0.index == currentIndex }),
            !usable.isEmpty
        else { return nil }

        let bounds = usable.reduce(CGRect.null) { partial, slot in
            partial.union(slot.frame)
        }
        let maximumWidth = usable.map(\.frame.width).max() ?? 0
        let maximumHeight = usable.map(\.frame.height).max() ?? 0
        let toleratedBounds = bounds.insetBy(
            dx: -maximumWidth * horizontalExitTolerance,
            dy: -maximumHeight * verticalExitTolerance
        )
        guard toleratedBounds.contains(point) else { return nil }

        guard
            let candidate = usable.min(by: {
                $0.frame.center.distanceSquared(to: point)
                    < $1.frame.center.distanceSquared(to: point)
            }), candidate.index != currentIndex
        else { return nil }

        let origin = current.frame.center
        let destination = candidate.frame.center
        let dx = destination.x - origin.x
        let dy = destination.y - origin.y
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared > 0 else { return nil }

        let progress =
            ((point.x - origin.x) * dx
                + (point.y - origin.y) * dy) / distanceSquared
        guard progress >= commitProgress else { return nil }
        return candidate.index
    }
}

private extension CGRect {
    var isUsableGridSlot: Bool {
        !isNull
            && !isInfinite
            && !isEmpty
            && minX.isFinite
            && minY.isFinite
            && width.isFinite
            && height.isFinite
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
