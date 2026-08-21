import SwiftUI
import CodevisorCore
import CodevisorUI

/// One native-style tab segment shared by every strip.
struct PaneTab: View {
    @Environment(\.theme) private var theme
    let name: String
    let kind: PaneKind
    let isAgentOwned: Bool
    var pluginId: String? = nil
    var pluginPaneType: String? = nil
    var pluginIconClient: (any CodevisorServerClienting)? = nil
    var pluginIconCacheNamespace = "preview"
    let isSelected: Bool
    let isDragging: Bool
    let width: CGFloat
    let canClose: Bool
    let showsTrailingSeparator: Bool
    let shortcutHint: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var showsHint: Bool { shortcutHint != nil && width >= 90 }
    private var fitsCloseButton: Bool { width >= 64 }
    private var showsIcon: Bool { width >= 48 }
    private var isSliver: Bool { width < 48 }

    private var contentSideReserve: CGFloat {
        if width >= 90 { return 30 }
        if canClose && fitsCloseButton { return 24 }
        return 0
    }

    private var contentPadding: CGFloat { 8 }
    private var capsuleInset: CGFloat { 2 }
    private var barHeight: CGFloat { PaneTabStripStyle.barHeight }
    private var capsuleHeight: CGFloat { barHeight - 2 * capsuleInset }

    private var iconName: String {
        switch kind {
        case .chat: "text.bubble"
        case .terminal: isAgentOwned ? "server.rack" : "terminal"
        case .newTab: "square.dashed"
        case .plugin: "puzzlepiece.extension"
        }
    }

    private var iconHelp: String {
        switch kind {
        case .chat: "Chat"
        case .terminal: isAgentOwned ? "Agent background process" : "Terminal"
        case .newTab: "New tab"
        case .plugin: "Plugin pane"
        }
    }

    var body: some View {
        capsuleContent
            .background {
                Group {
                    if isSelected && theme.isSystem {
                        Color.clear
                            .glassEffect(.regular, in: Capsule())
                            .glassEffectTransition(.identity)
                            .overlay(Capsule().strokeBorder(theme.border))
                    } else if isSelected {
                        Capsule()
                            .fill(theme.rowSelectedBackground)
                            .overlay(Capsule().strokeBorder(theme.border))
                    } else {
                        Capsule().fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                    }
                }
                .transaction { $0.animation = nil }
            }
            .overlay(alignment: .leading) {
                if canClose && isHovered && fitsCloseButton {
                    closeButton
                        .padding(.leading, capsuleInset + 5)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                if showsHint, let shortcutHint {
                    Text(shortcutHint)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.trailing, capsuleInset + 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsHint)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .padding(.horizontal, capsuleInset)
            .frame(width: width, height: barHeight)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(theme.separator)
                    .frame(width: 1, height: 14)
                    .offset(x: 0.5)
                    .opacity(showsTrailingSeparator ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: showsTrailingSeparator)
            }
            .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 3, y: 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { isHovered = $0 }
    }

    private var capsuleContent: some View {
        HStack(spacing: 4) {
            if showsIcon {
                tabIcon
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                    )
                    .help(iconHelp)
            }
            Text(name)
                .font(.tabLabel())
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.horizontal, isSliver ? 5 : contentPadding)
        .padding(.horizontal, contentSideReserve)
        .frame(maxWidth: .infinity, alignment: isSliver ? .leading : .center)
        .frame(height: capsuleHeight)
    }

    @ViewBuilder
    private var tabIcon: some View {
        if kind == .plugin, let pluginId, let pluginIconClient {
            PluginIconView(
                pluginId: pluginId,
                paneType: pluginPaneType,
                iconPath: "server",
                client: pluginIconClient,
                cacheNamespace: pluginIconCacheNamespace
            )
            .frame(width: 12, height: 12)
        } else {
            Image(systemName: iconName)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: Typography.IconSize.compact, weight: .bold))
                .foregroundStyle(isCloseHovered ? .primary : .secondary)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isCloseHovered ? 0.14 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .help("Close tab")
        .accessibilityLabel("Close tab")
    }
}
