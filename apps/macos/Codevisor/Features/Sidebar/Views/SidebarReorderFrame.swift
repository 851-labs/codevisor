import CodevisorUI
import SwiftUI

struct SidebarReorderFrame<RowID: Hashable>: ViewModifier {
  let reorder: SidebarReorder<RowID>
  let row: RowID
  @Environment(\.isSidebarRowLeaving) private var isLeaving

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: SidebarReorderSpace.coordinateSpace)
      } action: { frame in
        guard !isLeaving else { return }
        reorder.frames[row] = frame
      }
  }
}
