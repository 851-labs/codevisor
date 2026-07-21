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
    /// Run locations the new pane can open in: the project root plus the
    /// worktrees of the workspace's (unarchived) chats. The picker only
    /// shows when there is an actual choice.
    var contexts: [WorkspaceRunContext] = []
    /// The directory this placeholder was spawned FROM (the focused pane's
    /// context at ⌘T time). Preselects the matching context so a tab opened
    /// beside a worktree chat defaults into that worktree.
    var inheritedPath: String? = nil
    /// Creates the chat SESSION eagerly and converts the placeholder into
    /// an established chat pane (wired by the container, which owns session
    /// creation). Nil (previews) falls back to a draft conversion.
    var onNewChat: ((WorkspaceRunContext) -> Void)? = nil

    @State private var selectedContextId: String?

    private var selectedContext: WorkspaceRunContext? {
        if let selectedContextId,
           let picked = contexts.first(where: { $0.id == selectedContextId }) {
            return picked
        }
        if let inheritedPath,
           let inherited = contexts.first(where: { $0.path == inheritedPath }) {
            return inherited
        }
        return contexts.first
    }

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
                    if contexts.count > 1 {
                        contextPicker
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
        .simultaneousGesture(TapGesture().onEnded {
            group?.focusSelectedPane()
        })
    }

    /// Where the new tab opens — the same menu idiom as the composer's
    /// pickers: native checkmarks, a chip label showing the context NAME
    /// (project or worktree), with the ~-abbreviated path as a menu-row
    /// subtitle.
    private var contextPicker: some View {
        Menu {
            ForEach(contexts) { context in
                Toggle(isOn: Binding(
                    get: { context.id == selectedContext?.id },
                    set: { isOn in
                        guard isOn else { return }
                        selectedContextId = context.id
                    }
                )) {
                    Label {
                        Text(context.name)
                        Text(context.displayPath)
                    } icon: {
                        MenuSymbolIcon(systemName: context.symbolName)
                    }
                }
            }
        } label: {
            PickerChip(text: selectedContext?.name ?? "") {
                Image(systemName: selectedContext?.symbolName ?? "folder.fill")
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Directory for the new tab")
        .accessibilityValue(selectedContext?.name ?? "")
    }

    @ViewBuilder
    private var optionCards: some View {
        NewTabOptionCard(
            title: "New Chat",
            subtitle: "Start another chat in this workspace",
            systemImage: "text.bubble"
        ) {
            if let onNewChat, let selectedContext {
                onNewChat(selectedContext)
            } else {
                group?.convertNewTabPane(id: paneId, to: .chat)
            }
        }
        NewTabOptionCard(
            title: "New Terminal",
            subtitle: terminalSubtitle,
            systemImage: "terminal"
        ) {
            group?.convertNewTabPane(
                id: paneId, to: .terminal, cwd: selectedContext?.path
            )
        }
    }

    /// Names the actual destination, not a generic "workspace directory".
    private var terminalSubtitle: String {
        if let selectedContext {
            return "Open a shell in \(selectedContext.name)"
        }
        return "Open a shell in this workspace"
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
    NewTabPageView(
        paneId: UUID(),
        group: nil,
        contexts: [
            WorkspaceRunContext(
                kind: .projectRoot, name: "molina",
                path: "/Users/preview/dev/molina", worktreeName: nil
            ),
            WorkspaceRunContext(
                kind: .worktree, name: "ada-lovelace",
                path: "/Users/preview/codevisor/molina/ada-lovelace",
                worktreeName: "ada-lovelace"
            ),
        ]
    )
    .frame(width: 700, height: 480)
}
#endif
