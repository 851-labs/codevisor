import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

/// The trailing user bubble, with its attachment thumbnails above it as on
/// macOS. Optimistic and settled messages both render through this one view
/// under the same client-generated row identity.
struct UserBubbleRow: View {
    @Environment(\.theme) private var theme
    let text: String
    let attachments: [Attachment]

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
                                .foregroundColor: UIColor(theme.textPrimary),
                            ]
                        ),
                        fillsWidth: false
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        theme.bubbleBackground,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    MessageCopyButton(text: text, help: "Copy message")
                }
            }
        }
    }
}
