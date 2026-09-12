import CodevisorCore
import CodevisorUI
import SwiftUI

/// Project selection commits directly from the menu, like the run-location picker.
struct ComposerProjectMenu<MenuLabel: View>: View {
  @Environment(AppEnvironment.self) private var environment

  let currentProject: Project
  let onSelected: (Project) -> Void
  let onArchiveProject: (Project) -> Void
  @ViewBuilder let label: () -> MenuLabel

  @State private var isLoading = true
  @State private var hasLoadError = false
  @State private var showsProjectManagement = false

  private var serverId: String { currentProject.serverId }

  private var projects: [Project] {
    environment.projectList
      .fleetActiveProjectsByWorkspaceRecency(environment.workspaces.loadAll())
      .filter { $0.serverId == serverId && !$0.isScratch }
  }

  private var isPlaceholder: Bool {
    currentProject.isRunTargetPlaceholder || currentProject.isScratch
  }

  private var selection: Binding<UUID> {
    Binding(
      get: { isPlaceholder ? Project.runTargetPlaceholderID : currentProject.id },
      set: { id in
        if id == Project.runTargetPlaceholderID {
          if !isPlaceholder { onSelected(.runTargetPlaceholder(serverId: serverId)) }
        } else if let project = projects.first(where: { $0.id == id }) {
          onSelected(project)
        }
      }
    )
  }

  var body: some View {
    Menu {
      Section {
        Button("Manage projects…", systemImage: "gearshape") {
          showsProjectManagement = true
        }
      }

      Picker("Project", selection: selection) {
        Label("No project", systemImage: EntitySystemSymbol.projectList)
          .tag(Project.runTargetPlaceholderID)
        ForEach(projects) { project in
          Label(project.name, systemImage: EntitySystemSymbol.project)
            .tag(project.id)
        }
      }

      if projects.isEmpty {
        Section {
          if isLoading {
            Button("Loading Projects…") {}.disabled(true)
          } else if hasLoadError {
            Button("Retry Loading Projects", systemImage: "arrow.clockwise") {
              Task { await load() }
            }
          }
        }
      }
    } label: {
      label()
    }
    .menuIndicator(.hidden)
    .menuOrder(.fixed)
    .task(id: serverId) { await load() }
    .sheet(isPresented: $showsProjectManagement) {
      ManageProjectsSheet(serverId: serverId, onArchive: onArchiveProject)
    }
  }

  private func load() async {
    isLoading = true
    hasLoadError = false
    let result = await environment.projectList.refreshFromServer(
      serverId: serverId,
      client: environment.machines.client(for: serverId)
    )
    guard !Task.isCancelled else { return }
    if case .failed = result { hasLoadError = true }
    isLoading = false
  }
}
