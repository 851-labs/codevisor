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
    MessageBubbleView(side: .trailing, text: message.text, attachments: message.attachments, fill: style.fill) {
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
      side: .leading,
      text: message.text,
      attachments: message.attachments
    ) {
      StreamingMarkdownView(message.text)
        .frame(maxWidth: Self.naturalWidth(of: message.text), alignment: .leading)
    }
  }

  static func naturalWidth(of markdown: String) -> CGFloat {
    let body = NSFont.preferredFont(forTextStyle: .body)
    let code = NSFont.monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
    var inFence = false
    var widest: CGFloat = 0
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        inFence.toggle()
        continue
      }
      let font = inFence ? code : body
      let indent: CGFloat =
        !inFence && trimmed.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil ? 24 : 0
      let width = (String(line) as NSString).size(withAttributes: [.font: font]).width
      let codeSpans = inFence ? 0 : CGFloat(line.filter { $0 == "`" }.count / 2)
      widest = max(widest, ceil(width + indent + codeSpans * 14 + (inFence ? 24 : 4)))
    }
    return max(widest, 1)
  }
}

struct MessageBubbleView<Content: View>: View {
  enum Side {
    case leading
    case trailing
  }

  @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth
  let side: Side
  let text: String
  let attachments: [Attachment]
  var fill = Color.bubbleBackground
  @ViewBuilder let content: () -> Content

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
            .background { UserBubbleBackground(color: fill) }
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
