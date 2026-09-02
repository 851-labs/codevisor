import CodevisorCore
import SwiftUI

private let legacyProjectWorktreeBase = ProjectWorktreeBase(remote: "origin", branch: "main")

struct ManageProjectSheet: View {
  @Environment(\.dismiss) private var dismiss
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
    NavigationStack {
      Form {
        Section {
          if isLoading {
            HStack {
              Text("Base Branch")
              Spacer()
              ProgressView()
            }
          } else {
            NavigationLink {
              ProjectBaseBranchPicker(
                selection: $selectedBase,
                branches: branches
              )
            } label: {
              LabeledContent("Base Branch", value: baseBranchLabel)
            }
          }
        } header: {
          Text("Worktrees")
        } footer: {
          Text("New worktrees start from the latest commit on this remote branch.")
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }

        Section {
          Button("Archive Project…", role: .destructive) {
            isConfirmingArchive = true
          }
          .disabled(isSaving)
        }
      }
      .navigationTitle(project.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { Task { await save() } }
            .disabled(isSaving || isLoading)
        }
      }
    }
    .presentationDetents([.medium, .large])
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
    } message: {
      Text("This also archives the project's workspaces and chats.")
    }
  }

  private var baseBranchLabel: String {
    (selectedBase ?? legacyProjectWorktreeBase).displayName
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

private struct ProjectBaseBranchPicker: View {
  @Binding var selection: ProjectWorktreeBase?
  let branches: [ServerProjectGitBranch]
  @State private var searchText = ""

  var body: some View {
    List {
      if !branches.contains(where: {
        $0.worktreeBase == effectiveSelection
      }) {
        Section {
          branchButton(
            title: effectiveSelection.displayName,
            subtitle: "Currently unavailable",
            value: effectiveSelection
          )
        }
      }
      Section("Remote Branches") {
        if filteredBranches.isEmpty {
          Text(searchText.isEmpty ? "No remote branches found" : "No matching branches")
            .foregroundStyle(.secondary)
        } else {
          ForEach(filteredBranches) { branch in
            branchButton(
              title: branch.displayName,
              subtitle: branch.isDefault ? "Remote default" : nil,
              value: branch.worktreeBase
            )
          }
        }
      }
    }
    .navigationTitle("Base Branch")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search branches")
  }

  private var filteredBranches: [ServerProjectGitBranch] {
    guard !searchText.isEmpty else { return branches }
    return branches.filter {
      $0.displayName.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var effectiveSelection: ProjectWorktreeBase {
    selection ?? legacyProjectWorktreeBase
  }

  private func branchButton(
    title: String,
    subtitle: String?,
    value: ProjectWorktreeBase
  ) -> some View {
    Button {
      selection = value
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if effectiveSelection == value {
          Image(systemName: "checkmark")
            .fontWeight(.semibold)
        }
      }
    }
  }
}
