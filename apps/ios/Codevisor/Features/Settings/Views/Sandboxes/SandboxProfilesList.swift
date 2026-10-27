import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProfilesList: View {
  let model: SandboxSettingsModel
  let onEdit: (ServerSandboxProfile) -> Void
  let onEditProvider: (ServerSandboxProfile) -> Void
  let onDelete: (ServerSandboxProfile) -> Void

  var body: some View {
    Section("Profiles") {
      if model.profiles.isEmpty, model.hasLoaded {
        Text("No Profiles")
          .foregroundStyle(.secondary)
      }
      ForEach(model.profiles) { profile in
        Button {
          onEdit(profile)
        } label: {
          SandboxProfileListRow(profile: profile)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button("Delete", systemImage: "trash", role: .destructive) { onDelete(profile) }
            .labelStyle(.iconOnly)
        }
        .contextMenu {
          Button("Edit", systemImage: "pencil") { onEdit(profile) }
          if model.provider(profile.providerId) != nil {
            Button("Edit Provider", systemImage: "key") { onEditProvider(profile) }
          }
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive) { onDelete(profile) }
        }
      }
    }
  }
}
