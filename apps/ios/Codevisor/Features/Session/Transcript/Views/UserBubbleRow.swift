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
      if content.isStandaloneBlock {
        HStack {
          markdown
            .contextMenu {
              Button("Copy", systemImage: "doc.on.doc") { PlatformPasteboard.copy(content.text) }
            }
          Spacer(minLength: 40)
        }
        .padding(.vertical, 4)
      } else {
        MessageBubbleView(side: .leading, text: content.text, attachments: []) {
          markdown
        }
      }
      TranscriptInlineFileStack(files: content.files) { AttachmentThumbnailView(file: $0) }
    }
  }

  private var markdown: some View {
    MarkdownBlockGroupsView(blocks: content.blocks, documentSource: content.markdown, streamID: id)
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
  @State private var selection = TextSelectionSession()
  let side: Side
  let text: String
  let attachments: [Attachment]
  var fill = Color.bubbleBackground
  @ViewBuilder let content: () -> Content

  private var alignment: HorizontalAlignment { side == .trailing ? .trailing : .leading }

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
