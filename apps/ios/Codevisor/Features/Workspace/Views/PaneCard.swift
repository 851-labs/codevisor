import CodevisorCore
import SwiftUI
import UIKit

/// One grid card: reusable preview tile plus its label. The label never
/// participates in the lifted drag preview.
struct PaneCard: View {
    let pane: PaneDescriptorState
    let title: String
    let snapshot: UIImage?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMoveEarlier: (() -> Void)?
    let onMoveLater: (() -> Void)?

    private var symbolName: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .newTab: "plus.square.on.square"
        case .plugin: pane.pluginIcon ?? "puzzlepiece.extension"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            PanePreviewTile(
                pane: pane,
                snapshot: snapshot,
                title: title,
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
                Image(systemName: symbolName)
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
}
