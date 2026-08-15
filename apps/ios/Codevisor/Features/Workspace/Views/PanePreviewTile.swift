import CodevisorCore
import SwiftUI
import UIKit

/// The reusable preview rectangle. The grid card and native drag preview use
/// this exact surface and size; drag simply omits the close control.
struct PanePreviewTile: View {
    let pane: PaneDescriptorState
    let snapshot: UIImage?
    let title: String
    let showsCloseButton: Bool
    let onClose: () -> Void

    private var symbolName: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .newTab: "plus.square.on.square"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    pane.kind == .terminal
                        ? Color.black
                        : Color(.secondarySystemGroupedBackground)
                )
            if let snapshot {
                // Top-aligned fill inside the fixed card, overflow clipped
                // by the card shape.
                Color.clear
                    .overlay(alignment: .top) {
                        Image(uiImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: symbolName)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(
                            pane.kind == .terminal
                                ? Color.white.opacity(0.6)
                                : Color.secondary
                        )
                    Spacer()
                }
            }
        }
        // Fixed Safari-like height: every card matches regardless of how
        // tall its snapshot is.
        .frame(height: 205)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                        .shadow(
                            color: Color.black.opacity(0.16),
                            radius: 3,
                            x: 0,
                            y: 1
                        )
                }
                .buttonStyle(.plain)
                .padding(7)
                .accessibilityLabel("Close \(title)")
            }
        }
    }
}
