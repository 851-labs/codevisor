import CodevisorCore
import CodevisorUI
import SwiftUI

struct ProjectsSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @State private var showingAdd = false

  private var groups: [ProjectGroup] {
    environment.projectList.fleetActiveProjectGroups.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  private var readyMachineIds: [String] {
    environment.machines.allMachines
      .filter { environment.machines.availability(for: $0.id) == .ready }
      .map(\.id)
  }

  private var initialMachineId: String {
    if let preferred = SettingsRouter.shared.projectCreationMachineId,
      environment.machines.machine(for: preferred) != nil
    {
      return preferred
    }
    return environment.defaultComposerServerId
  }

  var body: some View {
    Form {
      Section {
        if groups.isEmpty {
          ContentUnavailableView(
            "No Projects", systemImage: "folder",
            description: Text("Add a folder or clone a repository to get started.")
          )
        } else {
          ForEach(groups) { group in
            NavigationLink(value: SettingsPaneRoute.project(group.id)) {
              HStack(spacing: 10) {
                Image(systemName: EntitySystemSymbol.project)
                  .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                  Text(group.name)
                  Text(group.repoKey ?? group.primary.folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(machineNames(for: group))
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
          }
        }
      } footer: {
        SettingsListActions {
          Button {
            showingAdd = true
          } label: {
            Label("Add Project…", systemImage: "plus")
          }
          .settingsActionTint(theme)
        }
      }
    }
    .settingsPaneFormStyle(theme)
    .sheet(isPresented: $showingAdd) {
      NewProjectSheet(serverId: initialMachineId) { project in
        SettingsRouter.shared.projectCreationMachineId = project.serverId
        SettingsRouter.shared.panePath = [.project(ProjectGroup.groupID(for: project))]
      }
    }
    .task(id: readyMachineIds) {
      await withTaskGroup(of: Void.self) { tasks in
        for serverId in readyMachineIds {
          let client = environment.machines.client(for: serverId)
          tasks.addTask { @MainActor in
            await environment.projectList.refreshFromServer(serverId: serverId, client: client)
          }
        }
      }
    }
  }

  private func machineNames(for group: ProjectGroup) -> String {
    var seen = Set<String>()
    return group.serverIds.filter { seen.insert($0).inserted }
      .map { environment.machines.machine(for: $0)?.name ?? "Unavailable machine" }
      .joined(separator: ", ")
  }
}

#Preview("Projects") {
  NavigationStack {
    ProjectsSettingsView()
  }
  .environment(AppEnvironment.preview())
  .frame(width: 580, height: 560)
}
