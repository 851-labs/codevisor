import CodevisorCore
import CodevisorUI
import SwiftUI

private let legacyProjectWorktreeBase = ProjectWorktreeBase(remote: "origin", branch: "main")

struct ManageProjectSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  let project: Project
  let client: any CodevisorServerClienting
  let didUpdate: () async -> Void
  let onArchive: () -> Void

  @State private var branches: [ServerProjectGitBranch] = []
  @State private var selectedBase: ProjectWorktreeBase?
  @State private var isLoading = true
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var isConfirmingArchive = false

  init(
    project: Project,
    client: any CodevisorServerClienting,
    didUpdate: @escaping () async -> Void,
    onArchive: @escaping () -> Void
  ) {
    self.project = project
    self.client = client
    self.didUpdate = didUpdate
    self.onArchive = onArchive
    _selectedBase = State(initialValue: project.worktreeBase)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: EntitySystemSymbol.project)
          .font(.title3)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(project.name)
            .font(.headline)
          Text("Project settings")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)

      Divider()
        .overlay(theme.isSystem ? Color.clear : theme.separator)

      Form {
        Section {
          if isLoading {
            LabeledContent("Base branch") {
              ProgressView()
                .controlSize(.small)
            }
          } else {
            Picker("Base branch", selection: selectedBaseBinding) {
              if !branches.contains(where: {
                $0.worktreeBase == effectiveSelectedBase
              }) {
                Text("\(effectiveSelectedBase.displayName) (Unavailable)")
                  .tag(effectiveSelectedBase)
              }
              ForEach(branches) { branch in
                Text(
                  branch.isDefault
                    ? "\(branch.displayName) (Default)"
                    : branch.displayName
                )
                .tag(branch.worktreeBase)
              }
            }
            .pickerStyle(.menu)
          }
        } header: {
          Text("Worktrees")
        } footer: {
          Text("New worktrees start from the latest commit on this remote branch.")
        }
        .listRowBackground(themedFormRowBackground)

        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(theme.statusError)
          }
          .listRowBackground(themedFormRowBackground)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(theme.isSystem ? .automatic : .hidden)

      Divider()
        .overlay(theme.isSystem ? Color.clear : theme.separator)
      HStack {
        Button("Archive Project…", role: .destructive) {
          isConfirmingArchive = true
        }
        .settingsActionTint(theme)
        .disabled(isSaving)
        Spacer()
        Button("Cancel") { dismiss() }
          .settingsActionTint(theme)
          .keyboardShortcut(.cancelAction)
        Button("Done") { Task { await save() } }
          .settingsActionTint(theme)
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || isLoading)
      }
      .padding()
      .themedSurface(.sheet)
    }
    .frame(width: 460, height: 330)
    .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
    .themedSurface(.sheet)
    .interactiveDismissDisabled(isSaving)
    .task { await loadBranches() }
    .confirmationDialog(
      "Archive \(project.name)?",
      isPresented: $isConfirmingArchive,
      titleVisibility: .visible
    ) {
      Button("Archive Project", role: .destructive) {
        onArchive()
        dismiss()
      }
      .settingsActionTint(theme)
      Button("Cancel", role: .cancel) {}
        .settingsActionTint(theme)
    } message: {
      Text(
        "This also archives the project's workspaces and chats. You can restore it from Archived."
      )
    }
  }

  private var selectedBaseBinding: Binding<ProjectWorktreeBase> {
    Binding(
      get: { effectiveSelectedBase },
      set: { selectedBase = $0 }
    )
  }

  private var effectiveSelectedBase: ProjectWorktreeBase {
    selectedBase ?? legacyProjectWorktreeBase
  }

  private var themedFormRowBackground: Color? {
    theme.isSystem ? nil : theme.cardQuietBackground
  }

  private func loadBranches() async {
    isLoading = true
    errorMessage = nil
    do {
      branches = try await client.listProjectGitBranches(projectId: project.id)
    } catch {
      errorMessage = serverErrorMessage(error)
    }
    isLoading = false
  }

  private func save() async {
    guard selectedBase != project.worktreeBase else {
      dismiss()
      return
    }
    isSaving = true
    errorMessage = nil
    do {
      _ = try await client.updateProjectWorktreeBase(
        id: project.id,
        worktreeBase: selectedBase
      )
      await didUpdate()
      dismiss()
    } catch {
      errorMessage = serverErrorMessage(error)
      isSaving = false
    }
  }
}
