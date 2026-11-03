import StreamMarkdown
import SwiftUI
import TranscriptKit

struct PluginAppBotBubble: View {
  @Environment(\.pluginAppHost) private var host
  let app: CodevisorExecutionApp

  var body: some View {
    if let host {
      HStack(spacing: 0) {
        PluginAppInlineView(model: model(host: host), host: host)
          .frame(maxWidth: Self.maximumWidth)
        Spacer(minLength: Self.trailingGap)
      }
      .environment(\.markdownBlockChrome, .bubble)
    }
  }

  private static var maximumWidth: CGFloat { 560 }
  private static var trailingGap: CGFloat { 40 }

  private func model(host: PluginAppHost) -> PluginAppInlineModel {
    PluginAppInlineModelCache.shared.model(for: app, chatMachineId: host.session.project.serverId)
  }
}
