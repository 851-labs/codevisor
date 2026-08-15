import SwiftUI

/// The workspace nav-bar controls: grid back button / New Chat chrome on the
/// leading edge, cancel / new-tab / show-tabs on the trailing edge.
struct WorkspaceScreenToolbar: ToolbarContent {
    let showsGrid: Bool
    let isNewChatPresentation: Bool
    let hasStarted: Bool
    let isFirstSendPromotionSurface: Bool
    let blocksServerContent: Bool
    let isDraft: Bool
    let onReopenSelectedPane: () -> Void
    let onDismissNewChat: () -> Void
    let onAddTab: () -> Void
    /// Reads the active pane at tap time, exactly as the inline button did.
    let onShowGrid: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if showsGrid, !isNewChatPresentation {
                Button {
                    onReopenSelectedPane()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back to selected tab")
            } else if isNewChatPresentation,
                hasStarted || isFirstSendPromotionSurface
            {
                Button {
                    onDismissNewChat()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Agents")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isNewChatPresentation, !hasStarted, !isFirstSendPromotionSurface {
                Button {
                    onDismissNewChat()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Cancel")
                // Tabs belong to a workspace; an unsent draft has none yet.
            } else if !blocksServerContent, !isDraft {
                if showsGrid {
                    Button {
                        onAddTab()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New tab")
                } else {
                    Button {
                        onShowGrid()
                    } label: {
                        Image(systemName: "square.on.square")
                    }
                    .accessibilityLabel("Show tabs")
                }
            }
        }
    }
}
