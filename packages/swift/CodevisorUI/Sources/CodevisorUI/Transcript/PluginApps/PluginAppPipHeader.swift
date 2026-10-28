import SwiftUI

struct PluginAppPipHeader: View {
  let model: PluginAppInlineModel
  let isRestricted: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button {
        model.request(.inline)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Close Picture in Picture")
      .accessibilityLabel("Close Picture in Picture")
      Text(model.app.serverName)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if !isRestricted, model.canPresent(.fullscreen) {
        PluginAppModeButton(mode: .fullscreen) { model.request(.fullscreen) }
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .frame(height: PluginAppPipLayout.headerHeight)
    .contentShape(Rectangle())
  }
}
