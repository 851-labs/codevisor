import SwiftUI

struct SidebarModePicker: View {
  @Binding var mode: SidebarMode

  var body: some View {
    Picker("Sidebar Mode", selection: $mode) {
      ForEach(SidebarMode.allCases, id: \.self) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
  }
}
