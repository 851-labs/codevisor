import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// One grid card: reusable preview tile plus its label. The label never
/// participates in the lifted drag preview.
struct PaneCard: View {
    let pane: PaneDescriptorState
    let title: String
    let snapshot: UIImage?
    let pluginIconClient: any CodevisorServerClienting
    let pluginIconCacheNamespace: String
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMoveEarlier: (() -> Void)?
    let onMoveLater: (() -> Void)?

    private var symbolName: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .newTab: "plus.square.on.square"
        case .plugin: "puzzlepiece.extension"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            PanePreviewTile(
                pane: pane,
                snapshot: snapshot,
                title: title,
                pluginIconClient: pluginIconClient,
                pluginIconCacheNamespace: pluginIconCacheNamespace,
                showsCloseButton: true,
                onClose: onClose
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { onSelect() }
            // The zoom endpoint is the preview itself—not its title row.
            // Matching this exact rectangle keeps the card mask and snapshot
            // aligned at the handoff frame.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PaneCardFramePreferenceKey.self,
                        value: [pane.id: proxy.frame(in: .global)]
                    )
                }
            }

            HStack(spacing: 5) {
                paneIcon
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) tab")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Move earlier") {
            onMoveEarlier?()
        }
        .accessibilityAction(named: "Move later") {
            onMoveLater?()
        }
        .transition(
            .scale(scale: 0.84, anchor: .center)
                .combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var paneIcon: some View {
        if pane.kind == .plugin, let pluginId = pane.pluginId {
            PluginIconView(
                pluginId: pluginId,
                paneType: pane.pluginPaneType,
                iconPath: "server",
                client: pluginIconClient,
                cacheNamespace: pluginIconCacheNamespace
            )
            .frame(width: 12, height: 12)
        } else {
            Image(systemName: symbolName)
        }
    }
}
