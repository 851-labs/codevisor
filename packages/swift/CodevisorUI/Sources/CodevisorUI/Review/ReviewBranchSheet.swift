#if !canImport(AppKit)
  import CodevisorCore
  import SwiftUI

  /// Base-branch selection on iPhone and iPad: a searchable list in a sheet,
  /// laid out like the project settings base-branch picker.
  struct ReviewBranchSheet: View {
    let model: ReviewPaneModel
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        List {
          section("Local Branches", matching(model.branchChoices.filter { !$0.remote }))
          section("Remote Branches", matching(model.branchChoices.filter(\.remote)))
        }
        .overlay {
          if model.refs == nil, model.isLoadingRefs {
            ProgressView()
          } else if !searchText.isEmpty, matching(model.branchChoices).isEmpty {
            ContentUnavailableView.search(text: searchText)
          }
        }
        .navigationTitle("Base Branch")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search branches")
        // Branch names are case-sensitive identifiers, not prose.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
          // Picking a row applies it immediately, so nothing is ever pending:
          // this only closes the sheet.
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
      .presentationDetents([.medium, .large])
      .task { await model.loadRefs() }
    }

    private func matching(_ branches: [ServerGitRefs.Branch]) -> [ServerGitRefs.Branch] {
      guard !searchText.isEmpty else { return branches }
      return branches.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    @ViewBuilder
    private func section(_ title: String, _ branches: [ServerGitRefs.Branch]) -> some View {
      if !branches.isEmpty {
        Section(title) {
          ForEach(branches) { branch in
            row(branch)
          }
        }
      }
    }

    private func row(_ branch: ServerGitRefs.Branch) -> some View {
      let isSelected = branch.name == model.baseDisplayName
      let isUnavailable = model.refs != nil && !(model.refs?.branches.contains(branch) ?? false)
      return Button {
        model.setBase(branch.name)
        dismiss()
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(branch.name)
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.middle)
            if isUnavailable {
              Text("Currently unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          if isSelected {
            Image(systemName: "checkmark")
              .fontWeight(.semibold)
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
          }
        }
      }
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
  }
#endif
