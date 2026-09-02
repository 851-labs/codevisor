import CodevisorCore
import CodevisorUI
import UIKit

/// The grid owns this lifted surface from long-press through release. Unlike
/// a system drag preview, it can land on the moving empty slot before the
/// canonical card is revealed, so there is no fade/pop or lost-delegate race.
struct WorkspaceTabGridDragState {
  let pane: PaneDescriptorState
  let title: String
  let snapshot: UIImage?
  let size: CGSize
  let grabOffset: CGSize
  /// Slot geometry is frozen at pickup. Live card frames animate after
  /// every reorder and must never become moving hit-test thresholds.
  let slots: [WorkspaceTabGridSlot]
  var currentSlotIndex: Int
  var fingerLocation: CGPoint
  var liftProgress: CGFloat
}
