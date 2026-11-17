import CodevisorCore
import CodevisorUI
import SwiftUI

struct ProjectSettingsRow: View {
  @Environment(AppEnvironment.self) private var environment
  let group: ProjectGroup
  @State private var confirmsDelete = false

  var body: some View {
    NavigationLink {
      ProjectSettingsScreen(groupId: group.id)
    } label: {
      label
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      ConfirmingDestructiveButton("Delete", systemImage: "trash") { confirmsDelete = true }
    }
    .contextMenu {
      Button("Delete…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
    }
    .confirmationDialog("Delete “\(group.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
      Button("Delete Project", role: .destructive) {
        environment.projectList.removeProjectGroup(group)
      }
      Button("Delete Project and Files", role: .destructive) {
        environment.projectList.removeProjectGroup(group, deletingFiles: true)
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var label: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
          .foregroundStyle(.primary)
        Text(group.repoKey ?? group.primary.folderURL.path)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    } icon: {
      Image(systemName: EntitySystemSymbol.project)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}
