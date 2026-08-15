import CodevisorUI
import SwiftUI

/// The iOS take on macOS's new-tab page: pick what this tab becomes. The
/// placeholder converts in place, so the tab keeps its slot in the grid.
struct NewTabPaneView: View {
    let projectName: String
    let onNewChat: () -> Void
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            newTabOption(
                title: "New Chat",
                subtitle: "Start an agent in \(projectName)",
                systemImage: "bubble.left.and.bubble.right",
                action: onNewChat
            )
            newTabOption(
                title: "New Terminal",
                subtitle: "Open a shell on the machine",
                systemImage: "terminal",
                action: onNewTerminal
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func newTabOption(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
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
