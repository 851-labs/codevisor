import CodevisorCore
import CodevisorUI
import SwiftUI

struct ProjectSettingsDetailView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let groupId: ProjectGroup.ID
  @State private var savingCheckoutIDs = Set<String>()

  private var group: ProjectGroup? {
    environment.projectList.fleetActiveProjectGroups.first { $0.id == groupId }
  }

  var body: some View {
    Form {
      if let group {
        if let repository = group.primary.repoUrl ?? group.repoKey {
          Section("Repository") {
            Text(repository)
              .textSelection(.enabled)
              .foregroundStyle(.secondary)
          }
        }
        ForEach(group.members, id: \.settingsCheckoutID) { project in
          ProjectCheckoutSettingsSection(
            project: project,
            allowsCheckoutDeletion: group.members.count > 1
          ) { saving in
            if saving {
              savingCheckoutIDs.insert(project.settingsCheckoutID)
            } else {
              savingCheckoutIDs.remove(project.settingsCheckoutID)
            }
          }
        }
        Section {
          ProjectSettingsDeleteButton(
            projects: group.members,
            title: "Delete Project…",
            confirmationTitle: "Delete \(group.name)?",
            message:
              "This permanently deletes all \(group.members.count) of this project's checkouts and every workspace and chat in them, along with their worktree files. This cannot be undone."
          ) {
            SettingsRouter.shared.panePath = []
          }
          .disabled(!savingCheckoutIDs.isEmpty)
        }
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
  }
}

private struct ProjectCheckoutSettingsSection: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let project: Project
  let allowsCheckoutDeletion: Bool
  let onSavingChanged: (Bool) -> Void
  @State private var editor: ProjectWorktreeSettingsModel

  init(project: Project, allowsCheckoutDeletion: Bool, onSavingChanged: @escaping (Bool) -> Void) {
    self.project = project
    self.allowsCheckoutDeletion = allowsCheckoutDeletion
    self.onSavingChanged = onSavingChanged
    _editor = State(initialValue: ProjectWorktreeSettingsModel(worktreeBase: project.worktreeBase))
  }

  private var machineName: String {
    environment.machines.machine(for: project.serverId)?.name ?? "Unavailable machine"
  }

  private var isReady: Bool {
    environment.machines.availability(for: project.serverId) == .ready
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: project.serverId)
  }

  var body: some View {
    Section {
      LabeledContent("Folder") {
        Text(project.folderURL.path)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
          .help(project.folderURL.path)
      }
      if !isReady {
        Label("Machine unavailable", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
      if project.isGitRepository {
        ProjectWorktreeSettingsEditor(model: editor, retry: loadBranches)
          .disabled(!isReady)
        HStack {
          Spacer()
          Button("Revert") { editor.revert() }
            .settingsActionTint(theme)
            .disabled(!editor.hasChanges || editor.isSaving)
          Button("Save") { Task { await save() } }
            .settingsActionTint(theme)
            .disabled(!isReady || !editor.hasChanges || editor.isSaving || editor.isLoading)
          if editor.isSaving { ProgressView().controlSize(.small) }
        }
      }
      if allowsCheckoutDeletion {
        ProjectSettingsDeleteButton(
          projects: [project],
          title: "Delete Checkout…",
          confirmationTitle: "Delete checkout on \(machineName)?",
          message:
            "This permanently deletes \(project.folderURL.path) from Codevisor along with its workspaces, chats and worktree files on \(machineName). Other checkouts are unchanged. This cannot be undone."
        ) {}
        .disabled(editor.isSaving)
      }
    } header: {
      Text(machineName)
    } footer: {
      if project.isGitRepository {
        Text("New worktrees start from the latest commit on this checkout's selected remote branch.")
      }
    }
    .task(id: isReady && project.isGitRepository) {
      // Even offline, finish the loading state and display the saved branch.
      if project.isGitRepository { await loadBranches() }
    }
    .onChange(of: project.worktreeBase) { _, base in editor.receive(base) }
  }

  private func loadBranches() async {
    await editor.load {
      guard isReady else { return [] }
      return try await client.listProjectGitBranches(projectId: project.id)
    }
  }

  private func save() async {
    onSavingChanged(true)
    defer { onSavingChanged(false) }
    _ = await editor.save { base in
      let updated = try await client.updateProjectWorktreeBase(id: project.id, worktreeBase: base)
      await environment.projectList.refreshFromServer(serverId: project.serverId, client: client)
      return updated.worktreeBase
    }
  }
}

private struct ProjectSettingsDeleteButton: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let projects: [Project]
  let title: String
  let confirmationTitle: String
  let message: String
  let onDeleted: () -> Void
  @State private var confirming = false

  var body: some View {
    Button(title, role: .destructive) { confirming = true }
      .settingsActionTint(theme)
      .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
        Button("Delete", role: .destructive) {
          projects.forEach(environment.projectList.removeProject)
          onDeleted()
        }
        .settingsActionTint(theme)
        Button("Cancel", role: .cancel) {}
          .settingsActionTint(theme)
      } message: {
        Text(message)
      }
  }
}

private extension Project {
  var settingsCheckoutID: String { "\(serverId)|\(id.uuidString)" }
}
