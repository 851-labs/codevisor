#if !canImport(AppKit)
  import SwiftUI

  /// A branch as `BranchPickerSheet` lists it.
  public struct BranchPickerItem: Identifiable, Hashable, Sendable {
    public let name: String
    /// A short note under the name ("Default", "Currently unavailable").
    public let note: String?
    public var id: String { name }

    public init(name: String, note: String? = nil) {
      self.name = name
      self.note = note
    }
  }

  /// A titled group of branches ("Local Branches", "Remote Branches").
  public struct BranchPickerSection: Identifiable, Sendable {
    public let title: String
    public let branches: [BranchPickerItem]
    public var id: String { title }

    public init(_ title: String, _ branches: [BranchPickerItem]) {
      self.title = title
      self.branches = branches
    }
  }

  /// Base-branch selection on iPhone and iPad: a searchable, checkmarked
  /// list in a sheet. Picking a row applies it and closes the sheet, so
  /// nothing is ever pending. Shared by the review pane and project settings.
  public struct BranchPickerSheet: View {
    let sections: [BranchPickerSection]
    let selection: String?
    let isLoading: Bool
    /// Shown when there is nothing to list and no search.
    let emptyMessage: String
    let onSelect: (String) -> Void
    let load: () async -> Void
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    public init(
      sections: [BranchPickerSection],
      selection: String?,
      isLoading: Bool,
      emptyMessage: String = "No Branches",
      onSelect: @escaping (String) -> Void,
      load: @escaping () async -> Void = {}
    ) {
      self.sections = sections
      self.selection = selection
      self.isLoading = isLoading
      self.emptyMessage = emptyMessage
      self.onSelect = onSelect
      self.load = load
    }

    public var body: some View {
      NavigationStack {
        List {
          ForEach(sections) { section in
            let branches = matching(section.branches)
            if !branches.isEmpty {
              Section(section.title) {
                ForEach(branches) { row($0) }
              }
            }
          }
        }
        .overlay {
          if isLoading, allBranches.isEmpty {
            ProgressView()
          } else if !searchText.isEmpty, matching(allBranches).isEmpty {
            ContentUnavailableView.search(text: searchText)
          } else if searchText.isEmpty, allBranches.isEmpty {
            ContentUnavailableView(emptyMessage, systemImage: "arrow.triangle.branch")
          }
        }
        .navigationTitle("Base Branch")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search branches")
        // Branch names are case-sensitive identifiers, not prose.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
          // Picking a row applies it immediately; this only closes the sheet.
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
      .presentationDetents([.medium, .large])
      .task { await load() }
    }

    private var allBranches: [BranchPickerItem] { sections.flatMap(\.branches) }

    private func matching(_ branches: [BranchPickerItem]) -> [BranchPickerItem] {
      guard !searchText.isEmpty else { return branches }
      return branches.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func row(_ branch: BranchPickerItem) -> some View {
      let isSelected = branch.name == selection
      return Button {
        onSelect(branch.name)
        dismiss()
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(branch.name)
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.middle)
            if let note = branch.note {
              Text(note)
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
