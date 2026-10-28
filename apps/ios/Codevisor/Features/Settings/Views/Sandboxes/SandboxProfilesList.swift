import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxProfilesList: View {
  let model: SandboxSettingsModel
  let onEdit: (ServerSandboxProfile) -> Void
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
          Button("Delete", systemImage: "trash", role: .destructive) { onDelete(profile) }
        }
      }
    }
  }
}
