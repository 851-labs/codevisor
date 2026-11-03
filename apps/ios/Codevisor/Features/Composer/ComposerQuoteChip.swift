import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerQuoteChip: View {
  let quote: TranscriptQuote
  let flightID: String
  let onOpen: () -> Void
  let onRemove: () -> Void

  var body: some View {
    TranscriptQuoteCard(quote: quote, onOpen: onOpen)
      .overlay(alignment: .topTrailing) {
        ComposerChipRemoveButton(accessibilityLabel: "Remove quote", action: onRemove)
          .offset(Self.removeButtonOverhang)
      }
      .transcriptSendAttachmentSource(
        id: flightID, image: nil, cornerRadius: TranscriptQuoteCard.cornerRadius, sentSize: ComposerChipMetrics.size
      )
      .accessibilityActions {
        Button("Remove", action: onRemove)
      }
  }

  private static let removeButtonOverhang = CGSize(width: 5, height: -5)
}
