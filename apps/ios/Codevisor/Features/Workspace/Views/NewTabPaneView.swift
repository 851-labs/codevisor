import CodevisorCore
import CodevisorUI
import SwiftUI

/// One plugin pane the New Tab page can open: a row per (plugin, pane type)
/// offered by the machine's installed plugins — the iOS twin of macOS's
/// New Tab plugin cards.
struct PluginNewTabOption: Identifiable, Equatable {
    var pluginId: String
    var pluginName: String
    var paneType: String
    var title: String
    var iconPath: String?

    var id: String { "\(pluginId)|\(paneType)" }
}

/// The iOS take on macOS's new-tab page: pick what this tab becomes. The
/// placeholder converts in place, so the tab keeps its slot in the grid.
struct NewTabPaneView: View {
    let projectName: String
    let onNewChat: () -> Void
    let onNewTerminal: () -> Void
    /// The machine's API client, for the machine-scoped plugin pane rows.
    /// Nil (previews) shows no plugin rows.
    var client: (any CodevisorServerClienting)? = nil
    var iconCacheNamespace = "preview"
    var onOpenPlugin: (PluginNewTabOption) -> Void = { _ in }

    @State private var pluginOptions: [PluginNewTabOption] = []

    var body: some View {
        // Centered while the options fit; scrolls when plugin rows outgrow
        // the pane (same pattern as macOS's NewTabPageView).
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    newTabOption(
                        title: "New Chat",
                        subtitle: "Start an agent in \(projectName)",
                        action: onNewChat
                    ) {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    newTabOption(
                        title: "New Terminal",
                        subtitle: "Open a shell on the machine",
                        action: onNewTerminal
                    ) {
                        Image(systemName: "terminal")
                    }
                    ForEach(pluginOptions) { option in
                        newTabOption(
                            title: option.title,
                            subtitle: option.pluginName,
                            action: { onOpenPlugin(option) }
                        ) {
                            if let client {
                                PluginIconView(
                                    pluginId: option.pluginId,
                                    paneType: option.paneType,
                                    iconPath: option.iconPath,
                                    client: client,
                                    cacheNamespace: iconCacheNamespace
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

    /// Machine-scoped plugin pane rows. Errors (older servers without the
    /// plugins feature, unreachable machines) just leave the rows hidden —
    /// the page's built-in options never depend on the request.
    private func loadPluginOptions() async {
        guard let client else { return }
        guard let plugins = try? await client.listPlugins() else { return }
        pluginOptions = plugins.flatMap { plugin in
            plugin.panes.map { pane in
                PluginNewTabOption(
                    pluginId: plugin.id,
                    pluginName: plugin.name,
                    paneType: pane.type,
                    title: pane.title,
                    iconPath: pane.iconPath ?? plugin.iconPath
                )
            }
        }
    }

    private func newTabOption<Icon: View>(
        title: String,
        subtitle: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                    .font(.title3)
                    .scaledFrame(width: 34, relativeTo: .title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
