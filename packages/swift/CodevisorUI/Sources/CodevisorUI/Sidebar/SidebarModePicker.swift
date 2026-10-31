import SwiftUI

public struct SidebarModePicker: View {
  @Binding var mode: SidebarMode

  public init(mode: Binding<SidebarMode>) {
    _mode = mode
  }

  public var body: some View {
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
