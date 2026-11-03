import Foundation

public struct TranscriptQuoteRevealRequest: Equatable, Sendable {
  public let id = UUID()
  public let quote: TranscriptQuote

  public init(quote: TranscriptQuote) {
    self.quote = quote
  }
}
