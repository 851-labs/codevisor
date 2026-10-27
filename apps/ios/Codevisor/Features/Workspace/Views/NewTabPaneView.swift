import CodevisorCore
import CodevisorUI
import SwiftUI

struct NewTabPaneView: View {
  let onNewChat: () -> Void
  let onNewTerminal: () -> Void
  var onNewBrowser: () -> Void = {}
  var onOpenFiles: () -> Void = {}
  var onReviewChanges: () -> Void = {}
  var onNewSimulator: () -> Void = {}
  var supportsSimulator = false
  var onNewScreenSharing: () -> Void = {}
  var supportsScreenSharing = false
  var client: (any CodevisorServerClienting)? = nil
  var iconCacheNamespace = "preview"
  var onOpenPlugin: (PluginPaneOffer) -> Void = { _ in }

  @State private var pluginOptions: [PluginPaneOffer] = []

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 14) {
          newTabOption(
            title: "New Chat",
            action: onNewChat
          ) {
            Image(systemName: "bubble.left.and.bubble.right")
          }
          newTabOption(
            title: "New Terminal",
            action: onNewTerminal
          ) {
            Image(systemName: "terminal")
          }
          newTabOption(title: "New Browser", action: onNewBrowser) {
            Image(systemName: "globe")
          }
          newTabOption(title: "Open File", action: onOpenFiles) {
            Image(systemName: "doc.text.magnifyingglass")
          }
          newTabOption(title: "Review Changes", action: onReviewChanges) {
            Image(systemName: "plusminus")
          }
          if supportsScreenSharing {
            newTabOption(title: "Open Desktop", action: onNewScreenSharing) {
              Image(systemName: "display")
            }
          }
          if supportsSimulator {
            newTabOption(title: "Open Simulator", action: onNewSimulator) {
              Image(systemName: "iphone")
            }
          }
          ForEach(pluginOptions) { option in
            newTabOption(
              title: option.title,
              action: { onOpenPlugin(option) }
            ) {
              if let client {
                PluginIconView(
                  pluginId: option.pluginId,
                  client: client,
                  cacheNamespace: iconCacheNamespace,
                  side: 24
                )
              } else {
                Image(systemName: "puzzlepiece.extension")
              }
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .frame(minHeight: geometry.size.height)
      }
    }
    .background(Color(.systemGroupedBackground))
    .task {
      await loadPluginOptions()
    }
  }

  private func loadPluginOptions() async {
    guard let client, let offers = await PluginPaneOffer.load(from: client) else { return }
    pluginOptions = offers
  }

  private func newTabOption<Icon: View>(
    title: String,
    action: @escaping () -> Void,
    @ViewBuilder icon: () -> Icon
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        icon()
          .font(.title3)
          .scaledFrame(width: 34, relativeTo: .title3)
          .foregroundStyle(.tint)
        Text(title)
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(16)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .pointerHighlight(RoundedRectangle(cornerRadius: 16))
  }
}
