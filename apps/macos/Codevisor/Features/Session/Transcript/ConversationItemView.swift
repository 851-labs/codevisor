import ACPKit
import AppKit
import CodevisorCore
import StreamMarkdown
import SwiftUI
import CodevisorUI
import TranscriptKit

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

struct UserMessageView: View {
  @Environment(\.userBubbleStyle) private var style
  let message: UserMessage

  var body: some View {
    MessageBubbleView(
      messageID: message.id.uuidString,
      side: .trailing,
      text: message.text,
      attachments: message.attachments,
      fill: style.fill
    ) {
      SelectableTextView(
        message.text,
        font: .preferredFont(forTextStyle: .body),
        foregroundColor: NSColor(style.text)
      )
    }
  }
}

struct BotMessageView: View {
  let message: TranscriptBotMessage

  var body: some View {
    MessageBubbleView(
      messageID: message.id,
      side: .leading,
      text: message.text,
      attachments: message.attachments
    ) {
      StreamingMarkdownView(message.text)
        .frame(maxWidth: TranscriptBotMessageWidth.natural(of: message.text), alignment: .leading)
    }
  }
}

struct MessageBubbleView<Content: View>: View {
  enum Side {
    case leading
    case trailing
  }

  @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let messageID: String
  let side: Side
  let text: String
  let attachments: [Attachment]
  var fill = Color.bubbleBackground
  @ViewBuilder let content: () -> Content

  private var isMenuTarget: Bool {
    TranscriptMessageMenuHighlight.shared.messageID == messageID
  }

  var body: some View {
    HStack {
      if side == .trailing { Spacer(minLength: 40) }
      VStack(alignment: side == .trailing ? .trailing : .leading, spacing: 8) {
        if !attachments.isEmpty {
          HStack(spacing: 8) {
            ForEach(attachments) { attachment in
              AttachmentThumbnailView(attachment: attachment)
            }
          }
        }
        if !text.isEmpty {
          content()
            .environment(
              \.streamMarkdownTextLayoutWidth,
              rowLayoutWidth.map { max(1, $0 - 64) }
            )
            .padding(.horizontal, TranscriptSendFlightGeometry.bubbleTextInsets.horizontal)
            .padding(.vertical, TranscriptSendFlightGeometry.bubbleTextInsets.vertical)
            .background {
              UserBubbleBackground(color: fill)
                .overlay {
                  UserBubbleBackground.shape(for: dynamicTypeSize)
                    .fill(Color.black.opacity(isMenuTarget ? 0.14 : 0))
                }
                .animation(.easeOut(duration: 0.15), value: isMenuTarget)
            }
        }
      }
      if side == .leading { Spacer(minLength: 40) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityActions {
      if !text.isEmpty {
        Button("Copy Message") { PlatformPasteboard.copy(text) }
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
