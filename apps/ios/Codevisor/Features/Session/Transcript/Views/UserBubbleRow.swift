import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

struct UserBubbleRow: View {
  @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let text: String
  let attachments: [Attachment]
  @State private var isSelecting = false

  var body: some View {
    HStack {
      Spacer(minLength: 40)
      VStack(alignment: .trailing, spacing: 8) {
        if !attachments.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(attachments) { attachment in
                AttachmentThumbnailView(attachment: attachment)
              }
            }
          }
          .defaultScrollAnchor(.trailing)
          .scrollBounceBehavior(.basedOnSize)
        }
        if !text.isEmpty {
          SelectableTextView(
            attributedText: NSAttributedString(
              string: text,
              attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor(Color.primary),
              ]
            ),
            fillsWidth: false,
            isSelecting: $isSelecting
          )
          .environment(
            \.streamMarkdownTextLayoutWidth,
            rowLayoutWidth.map { max(1, $0 - 64) }
          )
          .padding(.horizontal, TranscriptSendFlightGeometry.bubbleTextInsets.horizontal)
          .padding(.vertical, TranscriptSendFlightGeometry.bubbleTextInsets.vertical)
          .background {
            UserBubbleBackground(color: Color.bubbleBackground)
              .background(
                UserBubbleBackground.transcriptBackdrop(),
                in: UserBubbleBackground.shape(for: dynamicTypeSize))
          }
          .contentShape(.contextMenuPreview, UserBubbleBackground.shape(for: dynamicTypeSize))
          .contextMenu {
            if !isSelecting {
              Button("Copy", systemImage: "doc.on.doc") {
                PlatformPasteboard.copy(text)
              }
              Button("Select Text", systemImage: "selection.pin.in.out") {
                isSelecting = true
              }
            }
          }
        }
      }
    }
  }
}
