import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerProjectMenu<MenuLabel: View>: View {
  @Environment(AppEnvironment.self) private var environment

  let currentProject: Project
  let pendingSetupGroup: ProjectGroup?
  let onSelected: (Project) -> Void
  let onSetUp: (ProjectGroup) -> Void
  let onProjectDeleted: (ProjectGroup) -> Void
  @ViewBuilder let label: () -> MenuLabel

  @State private var isLoading = true
  @State private var hasLoadError = false
  @State private var showsProjectManagement = false

  private var serverId: String { currentProject.serverId }

  private static var noProjectTag: String { "no-project" }

  private var groups: [ProjectGroup] {
    environment.projectList.fleetActiveProjectGroupsByWorkspaceRecency(environment.workspaces.loadAll())
  }

  private var isPlaceholder: Bool {
    pendingSetupGroup == nil && (currentProject.isRunTargetPlaceholder || currentProject.isScratch)
  }

  private var selection: Binding<String> {
    Binding(
      get: {
        if let pendingSetupGroup { return pendingSetupGroup.id }
        if isPlaceholder { return Self.noProjectTag }
        return groups.first { $0.contains(currentProject) }?.id ?? Self.noProjectTag
      },
      set: { id in
        if id == Self.noProjectTag {
          if !isPlaceholder { onSelected(.runTargetPlaceholder(serverId: serverId)) }
        } else if let group = groups.first(where: { $0.id == id }) {
          if let project = group.member(on: serverId) {
            onSelected(project)
          } else {
            onSetUp(group)
          }
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
          .tag(Self.noProjectTag)
        ForEach(groups) { group in
          Label(group.name, systemImage: EntitySystemSymbol.project)
            .tag(group.id)
        }
      }

      if groups.isEmpty {
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
      ManageProjectsSheet(serverId: serverId, onDeleted: onProjectDeleted)
        .buttonStyle(.automatic)
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
