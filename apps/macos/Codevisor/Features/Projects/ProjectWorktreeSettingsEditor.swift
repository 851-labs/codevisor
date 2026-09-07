import CodevisorCore
import CodevisorUI
import SwiftUI

struct ProjectWorktreeSettingsEditor: View {
  @Environment(\.theme) private var theme
  @Bindable var model: ProjectWorktreeSettingsModel
  let retry: () async -> Void

  var body: some View {
    if model.isLoading {
      LabeledContent("Base branch") {
        ProgressView().controlSize(.small)
      }
    } else {
      Picker("Base branch", selection: selection) {
        if !model.branches.contains(where: { $0.worktreeBase == model.effectiveSelectedBase }) {
          Text("\(model.effectiveSelectedBase.displayName) (Unavailable)")
            .tag(model.effectiveSelectedBase)
        }
        ForEach(model.branches) { branch in
          Text(branch.isDefault ? "\(branch.displayName) (Default)" : branch.displayName)
            .tag(branch.worktreeBase)
        }
      }
      .pickerStyle(.menu)
      .disabled(model.isSaving)
    }
    if let error = model.errorMessage {
      HStack(alignment: .firstTextBaseline) {
        Text(error)
          .foregroundStyle(theme.statusError)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button("Reload Branches") { Task { await retry() } }
          .settingsActionTint(theme)
          .disabled(model.isSaving || model.isLoading)
      }
    }
  }

  private var selection: Binding<ProjectWorktreeBase> {
    Binding(
      get: { model.effectiveSelectedBase },
      set: { model.selectedBase = $0 }
    )
  }
}
