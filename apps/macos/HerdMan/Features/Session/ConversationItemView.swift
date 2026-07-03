import SwiftUI
import HerdManCore

/// Renders a single conversation item: a user prompt bubble or an assistant turn.
struct ConversationItemView: View {
    let item: ConversationItem

    var body: some View {
        switch item {
        case let .user(message):
            UserMessageView(message: message)
        case let .assistant(message):
            AssistantTurnView(turn: message.turn)
        }
    }
}

/// A right-aligned user prompt bubble, with any attachments rendered as
/// thumbnails above it.
struct UserMessageView: View {
    @Environment(\.theme) private var theme
    let message: UserMessage

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
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14).fill(theme.bubbleBackground))
                }
            }
        }
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
