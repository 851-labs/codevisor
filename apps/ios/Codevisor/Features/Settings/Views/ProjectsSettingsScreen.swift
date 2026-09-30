import CodevisorCore
import CodevisorUI
import SwiftUI

/// Every project across the fleet, one row per project however many
/// machines have it. Tap for its settings; swipe or long-press to delete.
struct ProjectsSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var deleting: ProjectGroup?
  @State private var addingOnMachine: AddTarget?

  private struct AddTarget: Identifiable {
    let id: String
  }

  private var groups: [ProjectGroup] {
    environment.projectList.fleetActiveProjectGroups.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  private var readyMachines: [CodevisorMachine] {
    environment.machines.allMachines.filter {
      !$0.isLocal && environment.machines.availability(for: $0.id) == .ready
    }
  }

  var body: some View {
    List {
      ForEach(groups) { group in
        NavigationLink {
          ProjectSettingsScreen(groupId: group.id)
        } label: {
          row(group)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) {
            deleting = group
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
        .contextMenu {
          Button("Delete…", systemImage: "trash", role: .destructive) { deleting = group }
        }
      }
    }
    .overlay {
      if groups.isEmpty {
        ContentUnavailableView {
          Label("No Projects", systemImage: EntitySystemSymbol.project)
        } description: {
          Text("Projects you add on any machine appear here.")
        }
      }
    }
    .animation(.default, value: groups.map(\.id))
    .navigationTitle("Projects")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { addToolbarItem }
    .refreshable { await refresh() }
    .task(id: readyMachines.map(\.id)) { await refresh() }
    .confirmationDialog(
      "Delete “\(deleting?.name ?? "Project")”?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible,
      presenting: deleting
    ) { group in
      Button("Delete Project", role: .destructive) {
        environment.projectList.removeProjectGroup(group)
      }
      Button("Delete Project and Files", role: .destructive) {
        environment.projectList.removeProjectGroup(group, deletingFiles: true)
      }
      Button("Cancel", role: .cancel) {}
    }
    .sheet(item: $addingOnMachine) { target in
      ManageProjectsSheet(serverId: target.id, onDeleted: { _ in })
    }
  }

  private func row(_ group: ProjectGroup) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
          .foregroundStyle(.primary)
        Text(machineNames(for: group))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } icon: {
      Image(systemName: EntitySystemSymbol.project)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  /// Adding a project means choosing a folder on a particular machine, so
  /// with several machines the button asks which one first.
  @ToolbarContentBuilder
  private var addToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      if readyMachines.count > 1 {
        Menu {
          Section("Add a Project on") {
            ForEach(readyMachines, id: \.id) { machine in
              Button(machine.name, systemImage: EntitySystemSymbol.machine(machine)) {
                addingOnMachine = AddTarget(id: machine.id)
              }
            }
          }
        } label: {
          Label("Add Project", systemImage: "plus")
        }
      } else {
        Button("Add Project", systemImage: "plus") {
          if let machine = readyMachines.first { addingOnMachine = AddTarget(id: machine.id) }
        }
        .disabled(readyMachines.isEmpty)
      }
    }
  }

  private func machineNames(for group: ProjectGroup) -> String {
    var seen = Set<String>()
    return group.serverIds.filter { seen.insert($0).inserted }
      .map(machineName)
      .joined(separator: ", ")
  }

  private func machineName(_ serverId: String) -> String {
    environment.machines.machine(for: serverId)?.name ?? "Unavailable Machine"
  }

  private func refresh() async {
    let machines = readyMachines.map(\.id)
    await withTaskGroup(of: Void.self) { tasks in
      for serverId in machines {
        let client = environment.machines.client(for: serverId)
        tasks.addTask { @MainActor in
          await environment.projectList.refreshFromServer(serverId: serverId, client: client)
        }
      }
    }
  }
}

#if DEBUG
  #Preview("Projects") {
    NavigationStack {
      ProjectsSettingsScreen()
    }
    .environment(AppEnvironment.preview(seedProjects: ProjectSettingsPreviewData.projects, seedSessions: []))
  }
#endif
