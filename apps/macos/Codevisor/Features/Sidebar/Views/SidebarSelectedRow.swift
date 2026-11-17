import CodevisorUI
import SwiftUI

struct SidebarSelectedRow<Content: View>: View {
  let id: SidebarRowID
  let selection: SelectionMarkers<SidebarRowID>
  @ViewBuilder let content: (_ isSelected: Bool) -> Content

  var body: some View {
    content(selection.isSelected(id))
  }
}
