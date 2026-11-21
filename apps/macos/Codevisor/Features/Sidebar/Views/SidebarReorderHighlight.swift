import CodevisorUI
import SwiftUI

struct SidebarReorderHighlight<RowID: Hashable>: ViewModifier {
  let reorder: SidebarReorder<RowID>
  let section: UUID?

  func body(content: Content) -> some View {
    content.background(SidebarDropHighlight(isActive: reorder.isHeaderTarget(section)))
  }
}
