import SwiftUI

struct PluginAppPaneHeader: View {
  let model: PluginAppPaneModel
  let isRestricted: Bool
  let onBack: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onBack) {
        Label("Back to Chat", systemImage: "chevron.backward")
      }
      .buttonStyle(.borderless)
      Spacer(minLength: 0)
      Text(model.app.serverName)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      if !isRestricted, model.subject != nil, model.canEnterPip() {
        PluginAppModeButton(mode: .pip, action: model.enterPip)
      }
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
