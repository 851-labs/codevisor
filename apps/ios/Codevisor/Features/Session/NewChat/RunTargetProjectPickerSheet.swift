import CodevisorCore
import CodevisorUI
import SwiftUI

/// Project selection commits immediately; location has its own composer menu.
struct RunTargetProjectPickerSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let currentProject: Project
  let onSelected: (Project) -> Void
  @State private var creation: Creation?

  private enum Creation: String, Identifiable {
    case folder, repository
    var id: String { rawValue }
  }

  var body: some View {
    NavigationStack {
      ProjectSelectionScreen(
        serverId: currentProject.serverId,
        selectedProjectId: currentProject.isScratch ? Project.runTargetPlaceholderID : currentProject.id,
        onOpenFolder: { creation = .folder },
        onCloneRepository: { creation = .repository },
        onSelected: finish
      )
      .navigationTitle("Project")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .sheet(item: $creation) { creation in
      switch creation {
      case .folder:
        AddProjectSheet(serverId: currentProject.serverId, onAdded: finish)
      case .repository:
        GitCloneSheet(
          client: environment.machines.client(for: currentProject.serverId),
          machineName: environment.machines.machine(for: currentProject.serverId)?.name ?? "this machine",
          onCloned: finish
        )
      }
    }
  }

  private func finish(_ project: Project) {
    onSelected(project)
    dismiss()
  }
}
