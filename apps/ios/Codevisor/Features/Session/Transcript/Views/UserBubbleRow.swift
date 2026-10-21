import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

struct UserBubbleRow: View {
  @Environment(\.userBubbleStyle) private var style
  let text: String
  let attachments: [Attachment]

  var body: some View {
    MessageBubbleView(side: .trailing, text: text, attachments: attachments, fill: style.fill) {
      SelectableTextView(
        attributedText: NSAttributedString(
          string: text,
          attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor(style.text),
          ]
        ),
        fillsWidth: false
      )
    }
  }
}

struct BotBubbleRow: View {
  let id: String
  let content: TranscriptBotMessageContent

  var body: some View {
    VStack(alignment: .leading, spacing: TranscriptSendFlightGeometry.attachmentSpacing) {
      MessageBubbleView(side: .leading, text: content.text, attachments: []) {
        MarkdownBlockGroupsView(blocks: content.blocks, documentSource: content.markdown, streamID: id)
          .transcriptBotMessageWidth(fitting: content)
      }
      TranscriptInlineFileStack(files: content.files) { AttachmentThumbnailView(file: $0, inline: true) }
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
  @State private var selection = TextSelectionSession()
  let side: Side
  let text: String
  let attachments: [Attachment]
  var fill = Color.bubbleBackground
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack {
      if side == .trailing { Spacer(minLength: 40) }
      VStack(
        alignment: side == .trailing ? .trailing : .leading, spacing: TranscriptSendFlightGeometry.attachmentSpacing
      ) {
        if !attachments.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TranscriptSendFlightGeometry.attachmentSpacing) {
              ForEach(attachments) { attachment in
                AttachmentThumbnailView(attachment: attachment)
              }
            }
          }
          .defaultScrollAnchor(side == .trailing ? .trailing : .leading)
          .scrollBounceBehavior(.basedOnSize)
        }
        if !text.isEmpty {
          content()
            .environment(\.textSelectionSession, selection)
            .environment(
              \.streamMarkdownTextLayoutWidth,
              rowLayoutWidth.map { max(1, $0 - 64) }
            )
            .padding(.horizontal, TranscriptSendFlightGeometry.bubbleTextInsets.horizontal)
            .padding(.vertical, TranscriptSendFlightGeometry.bubbleTextInsets.vertical)
            .background {
              UserBubbleBackground(color: fill)
                .background(
                  UserBubbleBackground.transcriptBackdrop(),
                  in: UserBubbleBackground.shape(for: dynamicTypeSize))
            }
            .contentShape(.contextMenuPreview, UserBubbleBackground.shape(for: dynamicTypeSize))
            .contextMenu {
              if !selection.isActive {
                Button("Copy", systemImage: "doc.on.doc") {
                  PlatformPasteboard.copy(text)
                }
                Button("Select Text", systemImage: "selection.pin.in.out") {
                  selection.begin()
                }
              }
            }
        }
      }
      if side == .leading { Spacer(minLength: 40) }
    }
  }
}
