#if !canImport(AppKit)
  import CodevisorCore
  import SwiftUI

  /// The review pane's base-branch sheet: its local and remote branches in
  /// the shared `BranchPickerSheet`.
  struct ReviewBranchSheet: View {
    let model: ReviewPaneModel

    var body: some View {
      BranchPickerSheet(
        sections: [
          BranchPickerSection("Local Branches", items(model.branchChoices.filter { !$0.remote })),
          BranchPickerSection("Remote Branches", items(model.branchChoices.filter(\.remote))),
        ],
        selection: model.baseDisplayName,
        isLoading: model.refs == nil && model.isLoadingRefs,
        onSelect: { model.setBase($0) },
        load: { await model.loadRefs() }
      )
    }

    private func items(_ branches: [ServerGitRefs.Branch]) -> [BranchPickerItem] {
      branches.map { branch in
        let isUnavailable = model.refs != nil && !(model.refs?.branches.contains(branch) ?? false)
        return BranchPickerItem(name: branch.name, note: isUnavailable ? "Currently unavailable" : nil)
      }
    }
  }
#endif
