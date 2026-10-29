import CodevisorCore
import CodevisorUI
import SwiftUI

struct ProjectsSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
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
          Text("No Projects")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        } else {
          ForEach(groups) { group in
            NavigationLink(value: SettingsPaneRoute.project(group.id)) {
              HStack(spacing: 10) {
                Image(systemName: EntitySystemSymbol.project)
                  .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                  Text(group.name)
                  Text(group.repoKey ?? group.primary.folderURL.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
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
        }
      }
      if !readyMachineIds.isEmpty {
        Section {
          ForEach(readyMachineIds, id: \.self) { serverId in
            if let machine = environment.machines.machine(for: serverId) {
              ProjectCloneLocationRow(
                machine: machine,
                client: environment.machines.client(for: serverId)
              )
            }
          }
        } header: {
          Text("Clone Location")
        } footer: {
          Text(
            "When you start a chat in a project a machine doesn't have yet, Codevisor clones it here. If the project lives under your home folder on another machine, the same path is used when it's free."
          )
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showingAdd) {
      NewProjectSheet(serverId: initialMachineId) { project in
        SettingsRouter.shared.projectCreationMachineId = project.serverId
        SettingsRouter.shared.panePath = [.project(ProjectGroup.routeID(for: project))]
      }
    }
    .task(id: readyMachineIds) {
      let projectList = environment.projectList
      await withTaskGroup(of: Void.self) { tasks in
        for serverId in readyMachineIds {
          let client = environment.machines.client(for: serverId)
          tasks.addTask {
            await projectList.refreshFromServer(serverId: serverId, client: client)
          }
        }
      }
    }
  }
}

#Preview("Projects") {
  NavigationStack {
    ProjectsSettingsView()
  }
  .environment(AppEnvironment.preview())
  .frame(width: 580, height: 560)
}
