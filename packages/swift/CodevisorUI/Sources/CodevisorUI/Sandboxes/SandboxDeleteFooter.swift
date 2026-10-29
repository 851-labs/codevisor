import SwiftUI

struct SandboxDeleteFooter: View {
  let title: String
  let help: String
  let onDelete: () -> Void

  var body: some View {
    #if os(macOS)
      SettingsListActions {
        Button(title, role: .destructive, action: onDelete)
          .buttonStyle(.bordered)
          .help(help)
      }
    #endif
  }
}
