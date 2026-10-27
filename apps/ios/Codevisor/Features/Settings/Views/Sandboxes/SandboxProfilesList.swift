import CodevisorCore
import SwiftUI

struct SandboxProfilesList: View {
  let model: SandboxSettingsModel
  let onAdd: (ServerSandboxProviderInfo) -> Void
  let onEdit: (ServerSandboxProfile) -> Void
  let onDelete: (ServerSandboxProfile) -> Void

  var body: some View {
    Section {
      ForEach(model.profiles) { profile in
        Button {
          onEdit(profile)
        } label: {
          SandboxListRow(
            systemImage: SandboxTarget(profile: profile, provider: model.provider(profile.provider)).systemImage,
            title: profile.name,
            subtitle: model.summary(of: profile),
            isUntested: model.provider(profile.provider)?.tested == false
          )
        }
        .swipeActions {
          Button("Delete", role: .destructive) { onDelete(profile) }
        }
      }
      SandboxAddMenu(title: "Add Profile", providers: model.providers.providers, onPick: onAdd)
    } header: {
      Text("Profiles")
    } footer: {
      Text("Each profile shows up in the machine picker as “New” and its name. Use one profile per image.")
    }
  }
}
