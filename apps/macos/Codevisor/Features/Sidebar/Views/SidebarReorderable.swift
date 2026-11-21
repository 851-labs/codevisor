import CodevisorUI
import SwiftUI

struct SidebarReorderable<RowID: Hashable>: ViewModifier {
  let reorder: SidebarReorder<RowID>
  let row: RowID
  var isEnabled = true
  let lift: () -> Void
  let commit: (SidebarReorder<RowID>.Drop) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .opacity(reorder.isLifted(row) ? 0.4 : 1)
      .modifier(SidebarReorderFrame(reorder: reorder, row: row))
      .simultaneousGesture(gesture, including: isEnabled ? .all : .subviews)
  }

  private var gesture: some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: SidebarReorderSpace.coordinateSpace)
      .onChanged { value in
        if reorder.lifted == nil { withAnimation(Motion.quick(reduceMotion: reduceMotion)) { lift() } }
        guard reorder.isLifted(row) else { return }
        reorder.drag(by: value.translation.height)
      }
      .onEnded { value in
        guard reorder.isLifted(row) else { return }
        reorder.drag(by: value.translation.height)
        let drop = withAnimation(Motion.quick(reduceMotion: reduceMotion)) { reorder.drop() }
        if let drop { commit(drop) }
      }
  }
}
