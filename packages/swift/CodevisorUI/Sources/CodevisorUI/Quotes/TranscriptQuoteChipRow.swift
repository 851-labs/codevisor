import SwiftUI
import TranscriptKit

public struct TranscriptQuoteChipRow: View {
  @Environment(\.transcriptQuoteActions) private var actions
  let quotes: [TranscriptQuote]

  public init(quotes: [TranscriptQuote]) {
    self.quotes = quotes
  }

  public var body: some View {
    HStack(spacing: TranscriptSendFlightGeometry.attachmentSpacing) {
      ForEach(quotes) { quote in
        TranscriptQuoteCard(quote: quote, onOpen: { actions?.reveal(quote) })
          .transcriptSendAttachmentTarget(
            id: quote.id, cornerRadius: TranscriptQuoteCard.cornerRadius, fill: .bubbleBackground,
            stroke: .separatorColor)
      }
    }
  }
}
