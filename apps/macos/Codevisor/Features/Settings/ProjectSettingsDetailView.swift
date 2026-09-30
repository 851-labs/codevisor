import Autocomplete
import CodevisorCore
import CodevisorUI
import SwiftUI

/// One project's settings. A project checked out on several machines is
/// still one project: each setting applies to every checkout, and the
/// machines only appear as the places it lives.
struct ProjectSettingsDetailView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let groupId: ProjectGroup.ID
  @State private var branches = ProjectBaseBranchModel()
  @State private var confirmingDelete = false

  private var group: ProjectGroup? {
    environment.projectList.fleetActiveProjectGroups.first { $0.isNamed(by: groupId) }
  }

  var body: some View {
    Form {
      if let group {
        if group.isGitRepository || repository(of: group) != nil {
          projectSection(group)
        }
        locationsSection(group)
      } else {
        ContentUnavailableView {
          Label("Project Unavailable", systemImage: "folder")
        } description: {
          Text("This project may have been removed.")
        } actions: {
          Button("Back to Projects") { SettingsRouter.shared.panePath = [] }
            .settingsActionTint(theme)
        }
      }
    }
    .settingsPaneFormStyle(theme)
    .navigationTitle(group?.name ?? "Project")
    // Reload as checkouts come and go or their machines come online.
    .task(id: branchSources) { await loadBranches() }
    .confirmationDialog(
      "Delete “\(group?.name ?? "Project")”?",
      isPresented: $confirmingDelete,
      titleVisibility: .visible,
      presenting: group
    ) { group in
      Button("Delete Project", role: .destructive) { delete(group, deletingFiles: false) }
      Button("Delete Project and Files", role: .destructive) { delete(group, deletingFiles: true) }
      Button("Cancel", role: .cancel) {}
    }
    // One project, one base branch: bring along any checkout that differs.
    .task(id: group?.id) {
      if let group { environment.projectList.alignWorktreeBase(for: group) }
    }
  }

  // MARK: Sections

  private func repository(of group: ProjectGroup) -> String? {
    group.primary.repoUrl ?? group.repoKey
  }

  private func projectSection(_ group: ProjectGroup) -> some View {
    Section {
      if let repository = repository(of: group) {
        LabeledContent("Repository") {
          Text(repository)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(repository)
        }
      }
      if group.isGitRepository {
        LabeledContent("Base branch") {
          ProjectBaseBranchMenu(group: group, branches: branches) {
            Task { await loadBranches() }
          }
        }
      }
    } footer: {
      if group.isGitRepository {
        Text("New worktrees start from the latest commit on the base branch.")
      }
    }
  }

  private func locationsSection(_ group: ProjectGroup) -> some View {
    Section {
      ForEach(group.members, id: \.settingsCheckoutID) { project in
        LabeledContent {
          Text(project.folderURL.path)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(project.folderURL.path)
        } label: {
          HStack(spacing: 6) {
            Text(machineName(project.serverId))
            if !isReady(project.serverId) {
              Text("Offline")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    } header: {
      Text(group.members.count > 1 ? "Machines" : "Location")
    } footer: {
      SettingsListActions {
        Button(role: .destructive) {
          confirmingDelete = true
        } label: {
          Text("Delete…")
            .foregroundStyle(theme.statusError)
        }
        .help("Delete this project from Codevisor")
      }
    }
  }

  // MARK: Actions

  private var branchSources: [String] {
    (group?.members ?? []).filter(\.isGitRepository).map {
      "\($0.serverId)|\($0.id.uuidString)|\(isReady($0.serverId))"
    }
  }

  private func loadBranches() async {
    guard let group else { return }
    let checkouts = group.members.filter(\.isGitRepository)
    // Offline machines are skipped, not reported as failures.
    var clients: [String: any CodevisorServerClienting] = [:]
    for project in checkouts where isReady(project.serverId) {
      clients[project.serverId] = environment.machines.client(for: project.serverId)
    }
    await branches.load(checkouts) { [clients] project in
      guard let client = clients[project.serverId] else { return nil }
      return try await client.listProjectGitBranches(projectId: project.id)
    }
  }

  private func delete(_ group: ProjectGroup, deletingFiles: Bool) {
    environment.projectList.removeProjectGroup(group, deletingFiles: deletingFiles)
    SettingsRouter.shared.panePath = []
  }

  private func machineName(_ serverId: String) -> String {
    environment.machines.machine(for: serverId)?.name ?? "Unavailable machine"
  }

  private func isReady(_ serverId: String) -> Bool {
    environment.machines.availability(for: serverId) == .ready
  }
}

/// A searchable pop-up of every remote branch any checkout can start
/// worktrees from. Choosing one applies it to every machine at once.
private struct ProjectBaseBranchMenu: View {
  @Environment(AppEnvironment.self) private var environment
  let group: ProjectGroup
  let branches: ProjectBaseBranchModel
  let reload: () -> Void

  private struct Choice: Identifiable {
    let base: ProjectWorktreeBase
    let isDefault: Bool
    let isAvailable: Bool
    var id: ProjectWorktreeBase { base }
  }

  private var current: ProjectWorktreeBase { group.worktreeBase }

  private var choices: [Choice] {
    let listed = branches.branches.map {
      Choice(base: $0.worktreeBase, isDefault: $0.isDefault, isAvailable: true)
    }
    // Keep the saved branch visible (and checked) even when no machine
    // lists it right now.
    guard !listed.contains(where: { $0.base == current }), !branches.isLoading else {
      return listed
    }
    return [Choice(base: current, isDefault: false, isAvailable: false)] + listed
  }

  private var loadingState: Autocomplete.LoadingState {
    guard branches.branches.isEmpty else { return .ready }
    if branches.isLoading { return .loading("Loading branches…") }
    if let error = branches.errorMessage { return .failure(error) }
    return .ready
  }

  var body: some View {
    let selection = Binding<ProjectWorktreeBase>(
      get: { current },
      set: { environment.projectList.setWorktreeBase($0, for: group) }
    )
    Autocomplete.Menu {
      Autocomplete.Picker("Remote branches", selection: selection, options: choices) { choice in
        Autocomplete.Choice(choice.base.displayName, value: choice.base) {
          HStack(spacing: 6) {
            Text(choice.base.displayName)
            if choice.isDefault {
              Text("Default").foregroundStyle(.secondary)
            } else if !choice.isAvailable {
              Text("Unavailable").foregroundStyle(.secondary)
            }
          }
        }
      }
      .labelsHidden()
      Autocomplete.Footer(id: "actions") {
        Autocomplete.Action("Reload Branches", systemImage: "arrow.clockwise", action: reload)
          .disabled(branches.isLoading)
      }
    } label: {
      HStack(spacing: 4) {
        Text(current.displayName)
        Image(systemName: "chevron.up.chevron.down")
          .imageScale(.small)
          .foregroundStyle(.secondary)
      }
    }
    .autocompleteSearchLabel("Search branches")
    .autocompleteSearchPrompt("Search branches")
    .autocompleteEmptyMessage(
      "No matching branches",
      noItems: branches.reachedMachine ? "No remote branches" : "Branches appear when a machine is online"
    )
    .autocompleteLoadingState(loadingState)
    .fixedSize()
    .accessibilityLabel("Base branch")
    .accessibilityValue(current.displayName)
    .help("The branch new worktrees start from")
  }
}

private extension Project {
  var settingsCheckoutID: String { "\(serverId)|\(id.uuidString)" }
}
