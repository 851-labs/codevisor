#if canImport(AppKit)
  import Autocomplete
  import CodevisorCore
  import SwiftUI

  /// The Mac's base-branch button: the branch name as a text button beside
  /// the mode button, opening a searchable list, because repositories often
  /// carry hundreds of remote branches.
  struct ReviewBaseAutocomplete: View {
    let model: ReviewPaneModel

    var body: some View {
      Autocomplete.Menu {
        Autocomplete.Picker(
          "Branches",
          selection: Binding(get: { model.baseDisplayName }, set: { model.setBase($0) }),
          options: model.branchChoices
        ) { branch in
          Autocomplete.Choice(branch.name, value: branch.name)
        }
        .labelsHidden()
      } label: {
        // Matches the mode button's text-and-chevron look.
        HStack(spacing: 3) {
          Text(model.baseDisplayName)
            .lineLimit(1)
            .truncationMode(.middle)
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 220)
      }
      .fixedSize()
      .autocompleteSearchLabel("Search branches")
      .autocompleteEmptyMessage("No matching branches", noItems: "No branches")
      .autocompleteLoadingState(model.refs == nil && model.isLoadingRefs ? .loading("Loading branches…") : .ready)
      .accessibilityLabel("Base Branch, \(model.baseDisplayName)")
      .help("Choose the Branch to Compare With")
      // Local refs only, so this is fast and works offline.
      .task { await model.loadRefs() }
    }
  }
#endif
