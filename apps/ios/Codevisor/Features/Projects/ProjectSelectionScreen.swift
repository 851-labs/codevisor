import CodevisorCore
import CodevisorUI
import SwiftUI

/// The native iOS project step used by the run-target sheet. "No Project"
/// heads the list (the chat runs in its own folder), then this machine's
/// projects and recommendations, with project creation exposed as a
/// consistent add action.
struct ProjectSelectionScreen: View {
  @Environment(AppEnvironment.self) private var environment

  let serverId: String
  let onOpenFolder: () -> Void
  let onCloneRepository: () -> Void
  let onSelected: (Project) -> Void

  @State private var recommendations: [ProjectRecommendation] = []
  @State private var addingRecommendationPath: String?
  @State private var isLoading = true
  @State private var hasLoadError = false

  private var projects: [Project] {
    environment.projectList
      .fleetActiveProjectsByWorkspaceRecency(environment.workspaces.loadAll())
      .filter { $0.serverId == serverId && !$0.isScratch }
  }

  private var visibleRecommendations: [ProjectRecommendation] {
    let existingPaths = Set(projects.map { $0.folderURL.standardizedFileURL.path })
    return recommendations.filter {
      !existingPaths.contains($0.folderURL.standardizedFileURL.path)
    }
  }

  private var hasChoices: Bool {
    !projects.isEmpty || !visibleRecommendations.isEmpty
  }

  private var machineName: String {
    environment.machines.machine(for: serverId)?.name ?? "this machine"
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: serverId)
  }

  var body: some View {
    projectList
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          addProjectMenu
        }
      }
      .task(id: serverId) { await load() }
  }

  private var addProjectMenu: some View {
    Menu {
      Button(action: onOpenFolder) {
        Label("Open Folder…", systemImage: "folder.badge.plus")
      }
      Button(action: onCloneRepository) {
        Label("Clone Repository…", systemImage: "square.and.arrow.down")
      }
    } label: {
      Image(systemName: "plus")
    }
    .accessibilityLabel("Add Project")
  }

  private var projectList: some View {
    List {
      Section {
        Button {
          onSelected(.runTargetPlaceholder(serverId: serverId))
        } label: {
          projectRow(
            title: "No Project",
            path: "Runs in its own folder on \(machineName)",
            systemImage: EntitySystemSymbol.projectList
          )
        }
      }

      if !projects.isEmpty {
        Section("Projects") {
          ForEach(projects) { project in
            Button {
              onSelected(project)
            } label: {
              projectRow(
                title: project.name,
                path: project.folderURL.standardizedFileURL.path,
                systemImage: EntitySystemSymbol.project,
                showsDisclosure: project.isGitRepository
              )
            }
          }
        }
      }

      if !hasChoices {
        Section {
          unavailableContent
        }
      }

      if !visibleRecommendations.isEmpty {
        Section("Recommended") {
          ForEach(visibleRecommendations) { recommendation in
            Button {
              add(recommendation)
            } label: {
              projectRow(
                title: recommendation.name,
                path: recommendation.folderURL.standardizedFileURL.path,
                systemImage: "clock.arrow.circlepath",
                isWorking: addingRecommendationPath
                  == recommendation.folderURL.standardizedFileURL.path
              )
            }
            .disabled(addingRecommendationPath != nil)
          }
        }
      }

    }
  }

  /// The state of this machine's project list when it has nothing to show
  /// yet: loading, failed, or genuinely empty (add one from the toolbar).
  @ViewBuilder
  private var unavailableContent: some View {
    if isLoading {
      HStack {
        Spacer()
        ProgressView()
          .accessibilityLabel("Loading Projects")
        Spacer()
      }
    } else if hasLoadError {
      VStack(alignment: .leading, spacing: 8) {
        Label("Projects Unavailable", systemImage: "exclamationmark.triangle")
        Text("Codevisor couldn’t load projects from \(machineName).")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("Try Again") {
          Task { await load() }
        }
        .buttonStyle(.bordered)
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text("No Projects")
          .font(.headline)
        Text("Open a folder or clone a repository to add one.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func projectRow(
    title: String,
    path: String,
    systemImage: String,
    isWorking: Bool = false,
    showsDisclosure: Bool = false
  ) -> some View {
    HStack(spacing: 12) {
      if isWorking {
        ProgressView()
      } else {
        Image(systemName: systemImage)
          .foregroundStyle(.tint)
          .frame(width: 24)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        Text(Self.abbreviatedPath(path))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if showsDisclosure {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .contentShape(Rectangle())
  }

  private func load() async {
    if !hasChoices {
      isLoading = true
    }
    hasLoadError = false
    async let refresh: ServerNavigationRefreshResult = environment.projectList.refreshFromServer(
      serverId: serverId,
      client: client
    )
    let loadedRecommendations = try? await environment.recommendedProjects(serverId: serverId)
    if let loadedRecommendations {
      recommendations = loadedRecommendations
    }
    if case .failed = await refresh {
      hasLoadError = true
    }
    isLoading = false
  }

  private func add(_ recommendation: ProjectRecommendation) {
    guard addingRecommendationPath == nil else { return }
    addingRecommendationPath = recommendation.folderURL.standardizedFileURL.path
    Task {
      let project = await environment.projectList.addProject(
        folderURL: recommendation.folderURL,
        serverId: serverId,
        client: client
      )
      addingRecommendationPath = nil
      onSelected(project)
    }
  }

  private static func abbreviatedPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }
}
