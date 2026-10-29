import SwiftUI

struct SandboxProfileProviderSection: View {
  let title: String
  let onEdit: () -> Void

  var body: some View {
    Section {
      LabeledContent("Provider", value: title)
      #if os(iOS)
        Button("Edit Provider…", action: onEdit)
      #endif
    } footer: {
      #if os(macOS)
        SettingsListActions {
          Button("Edit Provider…", action: onEdit)
        }
      #endif
    }
  }
}
