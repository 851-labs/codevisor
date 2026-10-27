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

extension SidebarModePicker {
  static var minimumSidebarWidth: CGFloat {
    let windowControls: CGFloat = 92
    let picker: CGFloat = 111
    let toolbarItemPadding: CGFloat = 4
    let sidebarToggle: CGFloat = 44
    let trailingInset: CGFloat = 4
    return windowControls + toolbarItemPadding + picker + toolbarItemPadding + sidebarToggle + trailingInset
  }
}
