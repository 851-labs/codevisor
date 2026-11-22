import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

struct UserBubbleRow: View {
  @Environment(\.userBubbleStyle) private var style
  let message: UserMessage

  var body: some View {
    MessageBubbleView(
      side: .trailing, text: message.quotedPrompt, attachments: message.attachments, fill: style.fill
    ) {
      TranscriptQuotedMessageText(message.quotedPrompt, font: BodyTextMetrics.font, color: style.text)
    }
  }
}

struct BotBubbleRow: View {
  let message: TranscriptBotMessage
  let content: TranscriptBotMessageContent

  var body: some View {
    VStack(alignment: .leading, spacing: TranscriptSendFlightGeometry.attachmentSpacing) {
      part
      TranscriptInlineFileStack(files: content.files) { AttachmentThumbnailView(file: $0) }
        .environment(\.markdownBlockChrome, .bubble)
    }
  }

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
      side: .leading, text: TranscriptQuotedPrompt(text: content.copyText), attachments: [], insets: insets,
      content: body)
  }

  private var blockMarkdown: some View {
    markdown.environment(\.markdownBlockChrome, .bubble)
  }

  private var markdown: some View {
    MarkdownFragmentsView(fragments: content.fragments, documentSource: content.markdown, streamID: message.id)
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
  let text: TranscriptQuotedPrompt
  let attachments: [Attachment]
  var fill = Color.bubbleBackground
  var insets = TranscriptSendFlightGeometry.bubbleTextInsets
  @ViewBuilder let content: () -> Content

  private var alignment: HorizontalAlignment { side == .trailing ? .trailing : .leading }

  private var contentLayoutWidth: CGFloat? {
    rowLayoutWidth.map { TranscriptBubbleMetrics.contentWidth(inRow: $0, horizontalInset: insets.horizontal) }
  }

  var body: some View {
    HStack {
      if side == .trailing { Spacer(minLength: TranscriptBubbleMetrics.oppositeSideGap) }
      VStack(
        alignment: alignment, spacing: TranscriptSendFlightGeometry.attachmentSpacing
      ) {
        TranscriptInlineFileStack(files: attachments.map(PreviewFile.init(attachment:)), alignment: alignment) {
          AttachmentThumbnailView(file: $0)
        }
        if !text.text.isEmpty {
          content()
            .environment(\.textSelectionSession, selection)
            .environment(\.streamMarkdownTextLayoutWidth, contentLayoutWidth)
            .padding(.horizontal, insets.horizontal)
            .padding(.vertical, insets.vertical)
            .background {
              UserBubbleBackground(color: fill)
                .background(
                  UserBubbleBackground.transcriptBackdrop(),
                  in: UserBubbleBackground.shape(for: dynamicTypeSize))
            }
            .clipShape(UserBubbleBackground.shape(for: dynamicTypeSize))
            .contentShape(.contextMenuPreview, UserBubbleBackground.shape(for: dynamicTypeSize))
            .contextMenu {
              if !selection.isActive {
                Button("Copy", systemImage: "doc.on.doc") {
                  TranscriptQuotePasteboard.copy(text)
                }
                Button("Select Text", systemImage: "selection.pin.in.out") {
                  selection.begin()
                }
              }
            }
        }
      }
      if side == .leading { Spacer(minLength: TranscriptBubbleMetrics.oppositeSideGap) }
    }
  }
}
