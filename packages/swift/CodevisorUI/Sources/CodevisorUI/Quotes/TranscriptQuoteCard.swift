import SwiftUI
import TranscriptKit

public struct TranscriptQuoteCard: View {
  let quote: TranscriptQuote
  let onOpen: () -> Void

  public init(quote: TranscriptQuote, onOpen: @escaping () -> Void) {
    self.quote = quote
    self.onOpen = onOpen
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(quote.snippet)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(Self.lineLimit)
        .truncationMode(.tail)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      TranscriptQuoteCardLabel()
    }
    .padding(Self.padding)
    .frame(width: ComposerChipMetrics.side, height: ComposerChipMetrics.side)
    .background(Self.shape.fill(Color.bubbleBackground))
    .overlay(Self.shape.strokeBorder(.separator, lineWidth: 1))
    .contentShape(Self.shape)
    .onTapGesture(perform: onOpen)
    .help("Show the quoted text")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Quote: \(quote.snippet)")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, onOpen)
  }

  public static let cornerRadius = ComposerChipMetrics.cornerRadius
  public static let shape = RoundedRectangle(cornerRadius: cornerRadius)

  private static let lineLimit = 4
  private static let padding: CGFloat = 8
}

private struct TranscriptQuoteCardLabel: View {
  var body: some View {
    Label("Selection", systemImage: "text.quote")
      .font(.caption2.weight(.medium))
      .foregroundStyle(.primary)
      .labelStyle(.titleAndIcon)
      .lineLimit(1)
  }
}
