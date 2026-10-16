import ACPKit
import AppKit
import CodevisorCore
import StreamMarkdown
import SwiftUI
import CodevisorUI

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
  @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth
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
            foregroundColor: NSColor(Color.primary)
          )
          .environment(
            \.streamMarkdownTextLayoutWidth,
            rowLayoutWidth.map { max(1, $0 - 64) }
          )
          .padding(.horizontal, TranscriptSendFlightGeometry.bubbleTextInsets.horizontal)
          .padding(.vertical, TranscriptSendFlightGeometry.bubbleTextInsets.vertical)
          .background { UserBubbleBackground(color: Color.primary.opacity(0.08)) }
          MessageCopyButton(text: message.text, help: "Copy message", isRevealed: isHovered)
            .opacity(isHovered ? 1 : 0)
        }
      }
    }
    .hoverTracking($isHovered, respectsSuspension: false)
    .accessibilityElement(children: .contain)
    .accessibilityActions {
      if !message.text.isEmpty {
        Button("Copy Message") { PlatformPasteboard.copy(message.text) }
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
