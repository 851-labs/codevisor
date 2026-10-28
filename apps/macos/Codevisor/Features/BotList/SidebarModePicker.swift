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
  static func sidebarWidthFitting(pickerWidth: CGFloat?, showsWindowControls: Bool) -> CGFloat {
    let windowControls: CGFloat = 92
    let fullScreenLeadingInset: CGFloat = 6
    let fallbackPickerWidth: CGFloat = 112
    let toolbarItemPadding: CGFloat = 4
    let sidebarToggle: CGFloat = 44
    let trailingInset: CGFloat = 4
    return (showsWindowControls ? windowControls : fullScreenLeadingInset) + toolbarItemPadding
      + (pickerWidth ?? fallbackPickerWidth) + toolbarItemPadding + sidebarToggle + trailingInset
  }
}
