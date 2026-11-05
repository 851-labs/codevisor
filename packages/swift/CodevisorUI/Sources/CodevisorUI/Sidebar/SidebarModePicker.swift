import SwiftUI

public struct SidebarModePicker: View {
  @Binding var mode: SidebarMode
  let help: (SidebarMode) -> String

  public init(mode: Binding<SidebarMode>, help: @escaping (SidebarMode) -> String = \.title) {
    _mode = mode
    self.help = help
  }

  public var body: some View {
    Picker("Sidebar Mode", selection: $mode) {
      ForEach(SidebarMode.allCases, id: \.self) { mode in
        Text(mode.title)
          .help(help(mode))
          .tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
  }
}
