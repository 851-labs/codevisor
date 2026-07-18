//  The Chrome-style "New tab" page: what a group shows when its last real
//  pane closes. The empty state IS a tab (the strip never lies about what's
//  open); this page offers what to open in its place — choosing converts
//  the placeholder pane in place, so the tab slot and selection carry over.

import SwiftUI
import CodevisorCore

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

    var body: some View {
        // Scrolls when the pane is too short for the (possibly stacked)
        // cards — fixed-height content would otherwise fight the group's
        // layout and squeeze the tab bar. Centered while it fits.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Text("New tab")
                        .font(.system(size: 15, weight: .semibold))
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
            subtitle: "Open a shell in the workspace directory",
            systemImage: "terminal"
        ) {
            group?.convertNewTabPane(id: paneId, to: .terminal)
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
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(theme.textPrimary)
                    .frame(height: 32)
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
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
    NewTabPageView(paneId: UUID(), group: nil)
        .frame(width: 700, height: 480)
}
#endif
