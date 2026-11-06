import CoreGraphics

struct FloatingPaneActions {
  let move: (CGRect) -> Void
  let activate: () -> Void
  let returnToWorkspace: () -> Void
  let close: () -> Void
}
