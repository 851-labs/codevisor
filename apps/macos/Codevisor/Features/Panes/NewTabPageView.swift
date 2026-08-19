//  The Chrome-style "New tab" page: what a group shows when its last real
//  pane closes. The empty state IS a tab (the strip never lies about what's
//  open); this page offers what to open in its place — choosing converts
//  the placeholder pane in place, so the tab slot and selection carry over.
//  Everything opens in the workspace's one working directory.

import SwiftUI
import CodevisorCore
import CodevisorUI

/// One plugin pane the New Tab page can open: a card per (plugin, pane type)
/// offered by the machine's installed plugins.
private struct PluginPaneOption: Identifiable, Equatable {
    var pluginId: String
    var pluginName: String
    var paneType: String
    var title: String
    var icon: String?

    var id: String { "\(pluginId)|\(paneType)" }
}

struct NewTabPageView: View {
    @Environment(\.theme) private var theme
    /// The placeholder pane this page belongs to.
    let paneId: UUID
    /// The owning group; conversion happens through it.
    let group: PaneGroupModel?
    /// Creates the chat SESSION eagerly and converts the placeholder into
    /// an established chat pane (wired by the container, which owns session
    /// creation). Nil (previews) falls back to a draft conversion.
    var onNewChat: (() -> Void)? = nil
    /// The machine's API client, for the machine-scoped plugin pane cards.
    /// Nil (previews, machineless groups) shows no plugin cards.
    var client: (any CodevisorServerClienting)? = nil

    @State private var pluginOptions: [PluginPaneOption] = []

    var body: some View {
        // Scrolls when the pane is too short for the (possibly stacked)
        // cards — fixed-height content would otherwise fight the group's
        // layout and squeeze the tab bar. Centered while it fits.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Text("New tab")
                        // 15 pt = the macOS `.title3` text style.
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    // Side by side while the pane is wide enough; a narrow
                    // split column stacks the cards instead of clipping.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            optionCards
                        }
                        VStack(spacing: 14) {
                            optionCards
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .background(theme.paneBackground)
        // The placeholder has no editor of its own, so whitespace clicks
        // explicitly activate the group and clear any stale terminal/editor
        // first responder. Controls still perform their normal actions.
        .simultaneousGesture(
            TapGesture().onEnded {
                group?.focusSelectedPane()
            }
        )
        .task {
            await loadPluginOptions()
        }
    }

    /// Machine-scoped plugin pane cards. Errors (older servers without the
    /// plugins feature, unreachable machines) just leave the cards hidden —
    /// the page's built-in options never depend on the request.
    private func loadPluginOptions() async {
        guard let client else { return }
        guard let plugins = try? await client.listPlugins() else { return }
        pluginOptions = plugins.flatMap { plugin in
            plugin.panes.map { pane in
                PluginPaneOption(
                    pluginId: plugin.id,
                    pluginName: plugin.name,
                    paneType: pane.type,
                    title: pane.title,
                    icon: pane.icon
                )
            }
        }
    }

    @ViewBuilder
    private var optionCards: some View {
        NewTabOptionCard(
            title: "New Chat",
            subtitle: "Start another chat in this workspace",
            systemImage: "text.bubble"
        ) {
            if let onNewChat {
                onNewChat()
            } else {
                group?.convertNewTabPane(id: paneId, to: .chat)
            }
        }
        NewTabOptionCard(
            title: "New Terminal",
            subtitle: "Open a shell in this workspace",
            systemImage: "terminal"
        ) {
            group?.convertNewTabPane(id: paneId, to: .terminal)
        }
        ForEach(pluginOptions) { option in
            NewTabOptionCard(
                title: option.title,
                subtitle: option.pluginName,
                systemImage: option.icon ?? "puzzlepiece.extension"
            ) {
                group?.convertNewTabPane(
                    id: paneId,
                    to: .plugin,
                    name: option.title,
                    pluginId: option.pluginId,
                    pluginPaneType: option.paneType,
                    pluginIcon: option.icon
                )
            }
        }
    }
}

private struct NewTabOptionCard: View {
    @Environment(\.theme) private var theme
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    // HIG: avoid Light/Thin/Ultralight weights.
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(theme.textPrimary)
                    .frame(height: 32)
                VStack(spacing: 4) {
                    Text(title)
                        // 13 pt = the macOS `.body` text style.
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        // 11 pt = the macOS `.subheadline` text style.
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 18)
            .frame(width: 190, height: 128)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? theme.cardHoverBackground : theme.cardQuietBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

#if DEBUG
    #Preview {
        NewTabPageView(
            paneId: UUID(),
            group: nil
        )
        .frame(width: 700, height: 480)
    }
#endif
