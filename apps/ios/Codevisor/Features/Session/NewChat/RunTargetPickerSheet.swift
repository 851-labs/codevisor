import CodevisorCore
import CodevisorUI
import SwiftUI

/// The composer's single run-target picker: a stepped sheet that pushes
/// machine → project → run location as real navigation, so every step after
/// the first gets the system back button and swipe-back. Dismissing the
/// sheet itself (swipe down) is the cancel. Single-machine fleets start at
/// the project step; non-git projects skip the run-location step.
struct RunTargetPickerSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  /// The machine the draft currently targets (preselected), nil when the
  /// draft has no project yet.
  var initialServerId: String? = nil
  /// The draft's current project, for the run-location checkmarks.
  var currentProject: Project? = nil
  var currentWantsWorktree = false
  /// Called with the picked project and whether the chat should run in a
  /// new worktree. The sheet dismisses itself right after.
  let onFinish: (Project, Bool) -> Void

  private enum Route: Hashable {
    case projects(serverId: String)
    case runLocation(serverId: String, projectId: UUID)
  }

  private enum ProjectCreationSheet: Identifiable {
    case openFolder(serverId: String)
    case cloneRepository(serverId: String)

    var id: String {
      switch self {
      case let .openFolder(serverId):
        "open-folder:\(serverId)"
      case let .cloneRepository(serverId):
        "clone-repository:\(serverId)"
      }
    }
  }

  @State private var path: [Route] = []
  @State private var projectCreationSheet: ProjectCreationSheet?

  /// Every machine's projects, most recently used first (scratch backing
  /// projects are internal and never listed).
  private var pickerProjects: [Project] {
    environment.projectList.fleetActiveProjectsByWorkspaceRecency(
      environment.workspaces.loadAll()
    )
    .filter { !$0.isScratch }
  }

  private var machines: [CodevisorMachine] {
    environment.machines.allMachines
  }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if machines.count > 1 {
          machineStep
            .navigationTitle("Select Machine")
        } else {
          projectStep(
            serverId: machines.first?.id
              ?? initialServerId
              ?? environment.defaultComposerServerId
          )
          .navigationTitle("Select Project")
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: Route.self) { route in
        switch route {
        case let .projects(serverId):
          projectStep(serverId: serverId)
            .navigationTitle("Select Project")
            .navigationBarTitleDisplayMode(.inline)
        case let .runLocation(serverId, projectId):
          runLocationStep(serverId: serverId, projectId: projectId)
            .navigationTitle("Select Location")
            .navigationBarTitleDisplayMode(.inline)
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .sheet(item: $projectCreationSheet) { sheet in
      projectCreationView(for: sheet)
    }
  }

  // MARK: - Steps

  /// Machines are never disabled here: a machine with no projects opens an
  /// empty project step whose add action creates the first one.
  private var machineStep: some View {
    List {
      ForEach(machines) { machine in
        NavigationLink(value: Route.projects(serverId: machine.id)) {
          Label(machine.name, systemImage: EntitySystemSymbol.machine(machine))
            .foregroundStyle(Color.primary)
        }
      }
    }
  }

  private func projectStep(serverId: String) -> some View {
    ProjectSelectionScreen(
      serverId: serverId,
      onOpenFolder: { projectCreationSheet = .openFolder(serverId: serverId) },
      onCloneRepository: {
        projectCreationSheet = .cloneRepository(serverId: serverId)
      },
      onSelected: advance(with:)
    )
  }

  @ViewBuilder
  private func projectCreationView(for sheet: ProjectCreationSheet) -> some View {
    switch sheet {
    case let .openFolder(serverId):
      AddProjectSheet(serverId: serverId, onAdded: advance(with:))
    case let .cloneRepository(serverId):
      GitCloneSheet(
        client: environment.machines.client(for: serverId),
        machineName: environment.machines.machine(for: serverId)?.name ?? "this machine",
        serverId: serverId,
        onCloned: advance(with:)
      )
    }
  }

  private func runLocationStep(serverId: String, projectId: UUID) -> some View {
    let project = pickerProjects.first {
      $0.serverId == serverId && $0.id == projectId
    }
    let isCurrent =
      currentProject?.serverId == serverId
      && currentProject?.id == projectId
    return List {
      Button {
        if let project { finish(project, wantsWorktree: false) }
      } label: {
        pickRow(
          "Project Directory",
          systemImage: "folder.fill",
          isChecked: isCurrent && !currentWantsWorktree
        )
      }
      Button {
        if let project { finish(project, wantsWorktree: true) }
      } label: {
        pickRow(
          "New Worktree",
          systemImage: "arrow.triangle.branch",
          isChecked: isCurrent && currentWantsWorktree
        )
      }
    }
  }

  // MARK: - Flow

  /// A freshly added project continues the flow exactly like a tapped row.
  private func advance(with project: Project) {
    guard project.isGitRepository else {
      finish(project, wantsWorktree: false)
      return
    }
    path.append(.runLocation(serverId: project.serverId, projectId: project.id))
  }

  private func finish(_ project: Project, wantsWorktree: Bool) {
    onFinish(project, wantsWorktree)
    dismiss()
  }

  private func pickRow(_ title: String, systemImage: String, isChecked: Bool) -> some View {
    HStack {
      Label(title, systemImage: systemImage)
        .foregroundStyle(Color.primary)
      Spacer()
      if isChecked {
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
      }
    }
  }
}
