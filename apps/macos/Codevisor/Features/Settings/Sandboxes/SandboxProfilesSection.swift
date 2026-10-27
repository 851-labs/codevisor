import CodevisorCore
import SwiftUI

struct SandboxProfilesSection: View {
  let model: SandboxSettingsModel
  let onAdd: (ServerSandboxProviderInfo) -> Void
  let onEdit: (ServerSandboxProfile) -> Void
  let onDelete: (ServerSandboxProfile) -> Void

  var body: some View {
    Section {
      if model.profiles.isEmpty, model.hasLoaded {
        Text("No profiles yet")
          .foregroundStyle(.secondary)
      }
      ForEach(model.profiles) { profile in
        SandboxSettingsRow(
          systemImage: SandboxTarget(profile: profile, provider: model.provider(profile.provider)).systemImage,
          title: profile.name,
          subtitle: model.summary(of: profile),
          isUntested: model.provider(profile.provider)?.tested == false,
          onEdit: { onEdit(profile) },
          onDelete: { onDelete(profile) }
        )
      }
    } header: {
      HStack {
        Text("Profiles")
        Spacer()
        SandboxProviderMenu(title: "Add Profile", providers: model.providers.providers, onPick: onAdd)
      }
    } footer: {
      Text("Each profile shows up in the machine picker as “New” and its name. Use one profile per image.")
        .foregroundStyle(.secondary)
    }
  }
}
