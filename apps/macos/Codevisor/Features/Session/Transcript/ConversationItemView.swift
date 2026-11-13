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
      quotes: message.quotes,
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
    VStack(alignment: isTrailing ? .trailing : .leading, spacing: TranscriptSendFlightGeometry.attachmentSpacing) {
      part
      TranscriptInlineFileStack(files: content.files) { AttachmentThumbnailView(file: $0) }
        .environment(\.markdownBlockChrome, .bubble)
    }
  }

  private var isTrailing: Bool { message.side == .trailing }

  @ViewBuilder private var part: some View {
    switch content.partStyle {
    case .text:
      if !content.text.isEmpty {
        bubble(insets: TranscriptSendFlightGeometry.bubbleTextInsets) { markdown }
      }
    case .quote:
      bubble(insets: TranscriptSendFlightGeometry.bubbleTextInsets) { blockMarkdown }
    case .callout:
      if let callout = content.callout {
        bubble(insets: TranscriptSendFlightGeometry.bubbleTextInsets) {
          TranscriptBotCalloutView(callout: callout, streamID: message.id)
            .transcriptBotMessageWidth(fitting: content)
        }
      }
    case .code, .table:
      bubble(insets: (0, 0)) { blockMarkdown }
    case let .image(source, alt):
      TranscriptBotImagePart(source: source, alt: alt)
    }
  }

  private func bubble(
    insets: (horizontal: CGFloat, vertical: CGFloat), @ViewBuilder content body: @escaping () -> some View
  ) -> some View {
    MessageBubbleView(
      messageID: message.id, side: isTrailing ? .trailing : .leading, text: content.copyText, attachments: [],
      insets: insets, content: body)
  }

  private var blockMarkdown: some View {
    markdown.environment(\.markdownBlockChrome, .bubble)
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
  var quotes: [TranscriptQuote] = []
  var fill = Color.bubbleBackground
  var insets = TranscriptSendFlightGeometry.bubbleTextInsets
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
        if !quotes.isEmpty {
          TranscriptQuoteChipRow(quotes: quotes)
        }
        TranscriptInlineFileStack(files: attachments.map(PreviewFile.init(attachment:)), alignment: alignment) {
          AttachmentThumbnailView(file: $0)
        }
        if !text.isEmpty {
          content()
            .environment(
              \.streamMarkdownTextLayoutWidth,
              rowLayoutWidth.map { max(1, $0 - 64) }
            )
            .padding(.horizontal, insets.horizontal)
            .padding(.vertical, insets.vertical)
            .background {
              UserBubbleBackground(color: fill)
                .overlay {
                  UserBubbleBackground.shape(for: dynamicTypeSize)
                    .fill(Color.black.opacity(isMenuTarget ? 0.14 : 0))
                }
                .animation(.easeOut(duration: 0.15), value: isMenuTarget)
            }
            .clipShape(UserBubbleBackground.shape(for: dynamicTypeSize))
        }
      }
      if side == .leading { Spacer(minLength: 40) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityActions {
      if !text.isEmpty {
        Button("Copy") { PlatformPasteboard.copy(text) }
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
