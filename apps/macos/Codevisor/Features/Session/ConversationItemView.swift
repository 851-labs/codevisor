import ACPKit
import AppKit
import CodevisorCore
import StreamMarkdown
import SwiftUI

/// Renders a single conversation item: a user prompt bubble or an assistant turn.
struct ConversationItemView: View {
    let item: ConversationItem
    var isWaitingOnUser = false
    var waitingOnBackgroundTask: String? = nil
    var goalActivity: GoalActivity? = nil

    var body: some View {
        switch item {
        case let .user(message):
            UserMessageView(message: message)
        case let .assistant(message):
            AssistantTurnView(
                turn: message.turn,
                turnID: message.id,
                isWaitingOnUser: isWaitingOnUser,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                goalActivity: goalActivity
            )
        }
    }
}

/// A right-aligned user prompt bubble, with any attachments rendered as
/// thumbnails above it.
struct UserMessageView: View {
    @Environment(\.theme) private var theme
    let message: UserMessage
    @State private var isHovered = false

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            AttachmentThumbnailView(attachment: attachment)
                        }
                    }
                }
                if !message.text.isEmpty {
                    SelectableTextView(
                        message.text,
                        font: .preferredFont(forTextStyle: .body),
                        foregroundColor: NSColor(theme.textPrimary)
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(theme.bubbleBackground))
                    // Kept in the layout (hidden until hover) so the row
                    // height doesn't jump when the pointer enters.
                    MessageCopyButton(text: message.text, help: "Copy message", isRevealed: isHovered)
                        .opacity(isHovered ? 1 : 0)
                }
            }
        }
        // Whole-row hover target, full width and height: AppKit tracking
        // (not .onHover) so the transparent regions count too.
        // User prompts are immutable once sent, so their copy affordance stays
        // available even while the assistant response is streaming.
        .hoverTracking($isHovered, respectsSuspension: false)
    }
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(SampleData.conversation) { item in
                ConversationItemView(item: item)
            }
        }
        .padding()
    }
    .frame(width: 600, height: 560)
}
