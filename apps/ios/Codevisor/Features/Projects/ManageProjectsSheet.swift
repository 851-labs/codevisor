import CodevisorCore
import CodevisorUI
import SwiftUI

/// Project creation and settings live outside the composer's selection menu.
struct ManageProjectsSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  let serverId: String
  let onArchive: (Project) -> Void

  @State private var destination: Destination?
  @State private var isLoading = true
  @State private var hasLoadError = false

  private enum Destination: Identifiable {
    case folder, repository, project(Project)

    var id: String {
      switch self {
      case .folder: "folder"
      case .repository: "repository"
      case .project(let project): project.id.uuidString
      }
    }
  }

  private var projects: [Project] {
    environment.projectList.fleetActiveProjects
      .filter { $0.serverId == serverId && !$0.isScratch }
      .sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
      }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(projects) { project in
            Button {
              destination = .project(project)
            } label: {
              Label {
                VStack(alignment: .leading, spacing: 3) {
                  Text(project.name)
                    .foregroundStyle(.primary)
                  Text(project.folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
              } icon: {
                Image(systemName: EntitySystemSymbol.project)
              }
            }
          }
          if projects.isEmpty {
            if isLoading {
              ProgressView("Loading Projects…")
            } else if hasLoadError {
              Button("Retry Loading Projects", systemImage: "arrow.clockwise") {
                Task { await load() }
              }
            } else {
              ContentUnavailableView(
                "No Projects", systemImage: "folder",
                description: Text("Add a folder or clone a repository to get started.")
              )
            }
          }
        }
        Section {
          Button("Open Folder…", systemImage: "folder.badge.plus") { destination = .folder }
          Button("Clone Repository…", systemImage: "square.and.arrow.down") { destination = .repository }
        }
      }
      .navigationTitle("Projects")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDragIndicator(.visible)
    .task(id: serverId) { await load() }
    .sheet(item: $destination) { destination in
      switch destination {
      case .folder:
        AddProjectSheet(serverId: serverId) { _ in self.destination = nil }
      case .repository:
        GitCloneSheet(
          client: environment.machines.client(for: serverId),
          machineName: environment.machines.machine(for: serverId)?.name ?? "this machine",
          serverId: serverId,
          onCloned: { _ in self.destination = nil }
        )
      case .project(let project):
        ManageProjectSheet(
          project: project,
          client: environment.machines.client(for: serverId),
          didUpdate: { await load() },
          onArchive: { onArchive(project) }
        )
      }
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
