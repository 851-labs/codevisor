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
    case let .user(message) where message.isEvent:
      EmptyView()
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
  let content: TranscriptBotMessageContent

  var body: some View {
    VStack(alignment: .leading, spacing: TranscriptSendFlightGeometry.attachmentSpacing) {
      if content.isStandaloneBlock {
        HStack {
          markdown
          Spacer(minLength: 40)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityActions {
          Button("Copy Message") { PlatformPasteboard.copy(content.text) }
        }
      } else {
        MessageBubbleView(
          messageID: message.id,
          side: .leading,
          text: content.text,
          attachments: []
        ) {
          markdown
        }
      }
      TranscriptInlineFileStack(files: content.files) { AttachmentThumbnailView(file: $0) }
    }
  }

  private var markdown: some View {
    MarkdownBlockGroupsView(blocks: content.blocks, documentSource: content.markdown, streamID: message.id)
      .transcriptBotMessageWidth(fitting: content)
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

  private var alignment: HorizontalAlignment { side == .trailing ? .trailing : .leading }

  private var isMenuTarget: Bool {
    TranscriptMessageMenuHighlight.shared.messageID == messageID
  }

  var body: some View {
    HStack {
      if side == .trailing { Spacer(minLength: 40) }
      VStack(
        alignment: alignment, spacing: TranscriptSendFlightGeometry.attachmentSpacing
      ) {
        TranscriptInlineFileStack(files: attachments.map(PreviewFile.init(attachment:)), alignment: alignment) {
          AttachmentThumbnailView(file: $0)
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
