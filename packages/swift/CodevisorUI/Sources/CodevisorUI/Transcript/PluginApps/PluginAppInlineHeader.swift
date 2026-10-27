import CodevisorCore
import SwiftUI
import TranscriptKit

struct PluginAppInlineHeader: View {
  let model: PluginAppInlineModel
  let isRestricted: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "puzzlepiece.extension")
        .imageScale(.small)
      Text(model.app.serverName)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if offers(.pip) {
        PluginAppModeButton(mode: .pip) { model.request(.pip) }
      }
      if offers(.fullscreen) {
        PluginAppModeButton(mode: .fullscreen) { model.request(.fullscreen) }
      }
      if let subject = model.subject {
        PluginSafetyButton(subject: subject)
          .buttonStyle(.borderless)
          .controlSize(.small)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  private func offers(_ mode: PluginAppDisplayMode) -> Bool {
    !isRestricted && model.subject != nil && model.mode == .inline && model.canPresent(mode)
  }
}
