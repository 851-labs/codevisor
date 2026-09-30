import CodevisorCore
import CodevisorUI
import SwiftUI

/// One project's settings, pushed onto a navigation stack. A project on
/// several machines is still one project with one base branch, applied to
/// every checkout. Changes apply as soon as they're made, like the Settings
/// app.
struct ProjectSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let groupId: ProjectGroup.ID
  /// Runs after the project is deleted, before this screen closes.
  var onDeleted: (ProjectGroup) -> Void = { _ in }

  @State private var branches = ProjectBaseBranchModel()
  @State private var showsBranchPicker = false
  @State private var confirmingDelete = false

  private var group: ProjectGroup? {
    environment.projectList.fleetActiveProjectGroups.first { $0.isNamed(by: groupId) }
  }

  var body: some View {
    Group {
      if let group {
        form(group)
      } else {
        ContentUnavailableView(
          "Project Unavailable", systemImage: EntitySystemSymbol.project,
          description: Text("This project may have been deleted."))
      }
    }
    .navigationTitle(group?.name ?? "Project")
    .navigationBarTitleDisplayMode(.inline)
    // Reload as checkouts come and go or their machines come online.
    .task(id: branchSources) { await loadBranches() }
    // One project, one base branch: bring along any checkout that differs.
    .task(id: group?.id) {
      if let group { environment.projectList.alignWorktreeBase(for: group) }
    }
  }

  private func form(_ group: ProjectGroup) -> some View {
    Form {
      if group.isGitRepository {
        Section {
          Button {
            showsBranchPicker = true
          } label: {
            LabeledContent {
              Text(group.worktreeBase.displayName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            } label: {
              Text("Base Branch")
                .foregroundStyle(.primary)
            }
          }
        } footer: {
          Text("New worktrees start from the latest commit on the base branch.")
        }
        .sheet(isPresented: $showsBranchPicker) {
          branchPicker(group)
        }
      }

      Section {
        Button(role: .destructive) {
          confirmingDelete = true
        } label: {
          Text("Delete Project…")
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
        }
        // Anchored to the button so the iPad popover points at it.
        .confirmationDialog(
          "Delete “\(group.name)”?",
          isPresented: $confirmingDelete,
          titleVisibility: .visible
        ) {
          Button("Delete Project", role: .destructive) { delete(group, deletingFiles: false) }
          Button("Delete Project and Files", role: .destructive) { delete(group, deletingFiles: true) }
          Button("Cancel", role: .cancel) {}
        }
      }
    }
  }

  /// The shared base-branch sheet, listing every remote branch any
  /// checkout has. The saved branch stays listed even when no reachable
  /// machine has it right now.
  private func branchPicker(_ group: ProjectGroup) -> some View {
    let current = group.worktreeBase
    var choices = branches.branches.map {
      (base: $0.worktreeBase, item: BranchPickerItem(name: $0.displayName, note: $0.isDefault ? "Default" : nil))
    }
    if branches.reachedMachine, !branches.isLoading, !choices.contains(where: { $0.base == current }) {
      choices.insert((current, BranchPickerItem(name: current.displayName, note: "Currently unavailable")), at: 0)
    }
    let bases = Dictionary(choices.map { ($0.item.name, $0.base) }, uniquingKeysWith: { first, _ in first })
    return BranchPickerSheet(
      sections: [BranchPickerSection("Remote Branches", choices.map(\.item))],
      selection: current.displayName,
      isLoading: branches.isLoading,
      emptyMessage: branches.reachedMachine
        ? "No Remote Branches" : "Branches appear when one of this project’s machines is online.",
      onSelect: { name in
        guard let base = bases[name] else { return }
        environment.projectList.setWorktreeBase(base, for: group)
      },
      load: loadBranches
    )
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
    onDeleted(group)
    dismiss()
  }

  private func isReady(_ serverId: String) -> Bool {
    environment.machines.availability(for: serverId) == .ready
  }
}

/// Project settings presented on their own, outside Settings.
struct ProjectSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  let groupId: ProjectGroup.ID
  var onDeleted: (ProjectGroup) -> Void = { _ in }

  var body: some View {
    NavigationStack {
      ProjectSettingsScreen(groupId: groupId) { group in
        onDeleted(group)
        dismiss()
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

#if DEBUG
  /// One repository checked out on two machines, plus a folder on one.
  enum ProjectSettingsPreviewData {
    static let projects: [Project] = {
      func checkout(_ name: String, on serverId: String, path: String, repo: String?) -> Project {
        let id = UUID()
        return Project(
          id: id, serverId: serverId, name: name,
          locations: [
            ProjectLocation(projectId: id, serverId: serverId, folderPath: path, isGitRepository: repo != nil)
          ],
          repoUrl: repo.map { "https://github.com/acme/\($0).git" }, repoKey: repo.map { "github.com/acme/\($0)" },
          worktreeBase: repo == nil ? nil : ProjectWorktreeBase(remote: "origin", branch: "develop"))
      }
      return [
        checkout("storefront", on: "local", path: "/Users/dylan/src/storefront", repo: "storefront"),
        checkout("storefront", on: "studio", path: "/home/dylan/storefront", repo: "storefront"),
        checkout("notes", on: "local", path: "/Users/dylan/notes", repo: nil),
      ]
    }()
  }

  #Preview("Project on two machines") {
    NavigationStack {
      ProjectSettingsScreen(groupId: "repo|github.com/acme/storefront")
    }
    .environment(AppEnvironment.preview(seedProjects: ProjectSettingsPreviewData.projects, seedSessions: []))
  }
#endif
