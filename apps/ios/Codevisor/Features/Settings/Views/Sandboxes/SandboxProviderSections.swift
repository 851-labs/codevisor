import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProviderSections: View {
  let model: SandboxSettingsModel
  @Binding var sheet: SandboxSettingsSheet?
  let onOpen: (ServerSandboxProfile) -> Void

  var body: some View {
    ForEach(model.providers) { provider in
      SandboxProviderSection(provider: provider, model: model, sheet: $sheet, row: row)
    }
    if !model.profilesWithoutProvider.isEmpty {
      Section("Other Profiles") {
        ForEach(model.profilesWithoutProvider, content: row)
      }
    }
  }

  private func row(_ profile: ServerSandboxProfile) -> some View {
    Button {
      onOpen(profile)
    } label: {
      SandboxProfileListRow(profile: profile)
    }
    .buttonStyle(.plain)
  }
}
