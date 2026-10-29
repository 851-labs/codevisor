import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProfilesList: View {
  let model: SandboxSettingsModel
  let onOpen: (ServerSandboxProfile) -> Void

  var body: some View {
    Section("Profiles") {
      ForEach(model.profiles) { profile in
        Button {
          onOpen(profile)
        } label: {
          SandboxProfileListRow(profile: profile)
        }
        .buttonStyle(.plain)
      }
    }
  }
}
