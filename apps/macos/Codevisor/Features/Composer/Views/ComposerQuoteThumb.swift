import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerQuoteThumb: View {
  let quote: TranscriptQuote
  let flightID: String
  let onOpen: () -> Void
  let onRemove: () -> Void

  @State private var isHovered = false

  var body: some View {
    TranscriptQuoteCard(quote: quote, onOpen: onOpen)
      .overlay(alignment: .topTrailing) {
        ComposerChipRemoveButton(help: "Remove quote", accessibilityLabel: "Remove quote", action: onRemove)
          .padding(4)
          .opacity(isHovered ? 1 : 0)
          .allowsHitTesting(isHovered)
      }
      .transcriptSendAttachmentSource(
        id: flightID, image: nil, cornerRadius: TranscriptQuoteCard.cornerRadius, sentSize: ComposerChipMetrics.size
      )
      .onHover { hovering in
        guard hovering != isHovered else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isHovered = hovering }
      }
      .accessibilityActions {
        Button("Remove", action: onRemove)
      }
  }
}
