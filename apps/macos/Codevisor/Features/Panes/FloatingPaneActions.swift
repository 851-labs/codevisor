import CoreGraphics

struct FloatingPaneActions {
  let move: (CGRect) -> Void
  let activate: () -> Void
  let rename: (String) -> Void
  let newTab: () -> Void
  let returnToWorkspace: () -> Void
  let close: () -> Void
}

struct FloatingPaneDrag {
  let changed: (CGSize) -> Void
  let ended: () -> Void
}
