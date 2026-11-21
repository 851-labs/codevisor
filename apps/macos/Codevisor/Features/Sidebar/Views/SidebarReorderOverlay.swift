import CodevisorUI
import SwiftUI

struct SidebarReorderOverlay<RowID: Hashable, Ghost: View>: View {
  let reorder: SidebarReorder<RowID>
  @ViewBuilder let ghost: (SidebarReorder<RowID>.Lifted) -> Ghost

  var body: some View {
    if let lifted = reorder.lifted, let frame = reorder.ghostFrame {
      ZStack(alignment: .topLeading) {
        ghost(lifted)
          .frame(width: frame.width, height: frame.height)
          .sidebarDragLift()
          .position(x: frame.midX, y: frame.midY)
        if let line = reorder.insertionLine {
          SidebarPlacedInsertionLine(frame: line)
        }
      }
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }
}
