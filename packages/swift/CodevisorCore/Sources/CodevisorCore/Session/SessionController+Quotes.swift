import Foundation

extension SessionController {
  public func addQuote(_ quote: TranscriptQuote) {
    guard !quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    var quote = quote
    quote.sentAt = quote.sentAt ?? sentAt(ofMessage: quote.messageID)
    transcriptPickSignal &+= 1
    composerQuotes.append(quote)
  }

  public func removeQuote(id: String) {
    transcriptPickSignal &+= 1
    composerQuotes.removeAll { $0.id == id }
  }

  public func revealQuote(_ quote: TranscriptQuote) {
    quoteRevealRequest = TranscriptQuoteRevealRequest(quote: quote)
  }

  public var composerQuoteSendFlightIDs: [String] {
    composerQuotes.indices.map(TranscriptQuote.sendFlightID(at:))
  }

  public var hasComposerChips: Bool {
    !composerAttachments.isEmpty || !composerQuotes.isEmpty
  }

  public var hasComposerDraft: Bool {
    !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !composerAttachments.isEmpty
      || !composerQuotes.isEmpty
  }

  var composerPromptText: String {
    let typed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    return TranscriptQuotedPrompt(quotes: composerQuotes, text: typed).promptText
  }

  func takeComposerPromptText() -> String {
    let text = composerPromptText
    composerQuotes = []
    return text
  }

  func restoreComposerPrompt(_ promptText: String) {
    let prompt = TranscriptQuotedPrompt(promptText: promptText)
    composerQuotes = prompt.quotes
    composerText = prompt.text
  }

  private func sentAt(ofMessage messageID: String) -> Date? {
    let items = conversation
    guard let index = items.firstIndex(where: { $0.id.uuidString == messageID }) else { return nil }

    if case let .assistant(message) = items[index] { return message.turn.endedAt ?? message.turn.startedAt }
    return items[(index + 1)...].lazy.compactMap(Self.turnStart).first
  }

  private static func turnStart(_ item: ConversationItem) -> Date? {
    guard case let .assistant(message) = item else { return nil }
    return message.turn.startedAt
  }
}
