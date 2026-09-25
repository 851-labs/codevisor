import CodevisorCore
import CodevisorUI
import SwiftUI

/// Project creation and settings live outside the composer's selection menu.
///
/// One navigation stack: the machine's projects, folders you've recently
/// worked in (one tap adds), and a folder browser pushed in place. Adding is
/// immediate — the project registers locally and syncs through the outbox.
struct ManageProjectsSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  let serverId: String
  let onDelete: (Project) -> Void

  @State private var navigationPath = NavigationPath()
  @State private var modal: Modal?
  @State private var isLoading = true
  @State private var hasLoadError = false
  @State private var recommendations: [ProjectRecommendation]?

  private enum Modal: Identifiable {
    case repository, project(Project)

    var id: String {
      switch self {
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

  private var suggestions: [ProjectRecommendation] {
    let registered = environment.projectList.registeredFolderPaths(serverId: serverId)
    return (recommendations ?? []).filter {
      !registered.contains($0.folderURL.standardizedFileURL.path)
    }
  }

  private var machineName: String {
    environment.machines.machine(for: serverId)?.name ?? "this machine"
  }

  var body: some View {
    NavigationStack(path: $navigationPath) {
      List {
        projectsSection
        suggestionsSection
        Section {
          NavigationLink(value: RemoteDirectory.home) {
            Label("Choose Folder…", systemImage: "folder.badge.plus")
          }
          Button("Clone Repository…", systemImage: "arrow.down.circle") {
            modal = .repository
          }
        } header: {
          Text("Add Project")
        }
      }
      .animation(.default, value: projects.map(\.id))
      .navigationTitle("Projects")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .navigationDestination(for: RemoteDirectory.self) { directory in
        RemoteDirectoryScreen(
          serverId: serverId,
          directory: directory,
          onOpen: { navigationPath.append($0) },
          onPick: { addFolder(URL(fileURLWithPath: $0)) }
        )
      }
    }
    .presentationDragIndicator(.visible)
    .task(id: serverId) { await load() }
    .task(id: serverId) { await loadSuggestions() }
    .sheet(item: $modal) { modal in
      switch modal {
      case .repository:
        GitCloneSheet(
          client: environment.machines.client(for: serverId),
          machineName: machineName,
          serverId: serverId,
          onCloned: { _ in self.modal = nil }
        )
      case .project(let project):
        ManageProjectSheet(
          project: project,
          client: environment.machines.client(for: serverId),
          didUpdate: { await load() },
          onDelete: { onDelete(project) }
        )
      }
    }
  }

  // MARK: Sections

  private var projectsSection: some View {
    Section {
      ForEach(projects) { project in
        Button {
          modal = .project(project)
        } label: {
          FolderRow(name: project.name, path: project.folderURL.path, symbol: EntitySystemSymbol.project)
        }
      }
      if projects.isEmpty {
        if isLoading {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .accessibilityLabel("Loading Projects")
        } else if hasLoadError {
          Button("Retry Loading Projects", systemImage: "arrow.clockwise") {
            Task { await load() }
          }
        } else if suggestions.isEmpty {
          // With suggestions below, the first step is already on screen.
          Text("No Projects")
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      if !projects.isEmpty { Text(machineName) }
    }
  }

  @ViewBuilder
  private var suggestionsSection: some View {
    if !suggestions.isEmpty {
      Section {
        ForEach(suggestions) { suggestion in
          Button {
            addFolder(suggestion.folderURL)
          } label: {
            HStack(spacing: 12) {
              FolderRow(
                name: suggestion.name,
                path: suggestion.folderURL.deletingLastPathComponent().path,
                symbol: "folder"
              )
              .frame(maxWidth: .infinity, alignment: .leading)
              Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            }
          }
          .accessibilityLabel("Add \(suggestion.name)")
          .accessibilityHint(suggestion.folderURL.path)
        }
      } header: {
        Text("Recent Folders")
      }
    }
  }

  // MARK: Actions

  private func addFolder(_ url: URL) {
    // Registered locally at once; the outbox syncs it to the machine.
    withAnimation {
      _ = environment.projectList.addProject(folderURL: url, serverId: serverId)
      navigationPath = NavigationPath()
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

  /// Shows the machine's last suggestions at once, then refreshes them. A
  /// failure only hides the section; choosing a folder still works.
  private func loadSuggestions() async {
    recommendations = environment.cachedRecommendedProjects(serverId: serverId)
    guard let loaded = try? await environment.recommendedProjects(serverId: serverId),
      !Task.isCancelled
    else { return }
    withAnimation { recommendations = loaded }
  }
}

/// A folder's name over its location.
private struct FolderRow: View {
  let name: String
  let path: String
  let symbol: String

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .foregroundStyle(.primary)
        Text(path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    } icon: {
      Image(systemName: symbol)
    }
  }
}
