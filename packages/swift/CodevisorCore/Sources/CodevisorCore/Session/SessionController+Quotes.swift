import Foundation

extension SessionController {
  public var composerText: String {
    get { composerPrompt.text }
    set { composerPrompt = TranscriptQuotedPrompt(text: newValue, quotes: composerPrompt.quotes) }
  }

  public var composerQuotes: [TranscriptQuote] { composerPrompt.quotes }

  public func addQuote(_ quote: TranscriptQuote) {
    var quote = quote
    quote.text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !quote.text.isEmpty else { return }

    quote.sentAt = quote.sentAt ?? sentAt(ofMessage: quote.messageID)
    transcriptPickSignal &+= 1
    pendingQuoteInsertions.append(quote)
    addToChatSignal &+= 1
  }

  public func finishQuoteInsertions(_ ids: Set<String>) {
    pendingQuoteInsertions.removeAll { ids.contains($0.id) }
  }

  public func revealQuote(_ quote: TranscriptQuote) {
    quoteRevealRequest = TranscriptQuoteRevealRequest(quote: quote)
  }

  public var hasComposerChips: Bool {
    !composerAttachments.isEmpty
  }

  public var hasComposerDraft: Bool {
    !composerPrompt.isEmpty || !composerAttachments.isEmpty
  }

  var composerPromptText: String {
    composerPrompt.trimmed.promptText
  }

  func takeComposerPromptText() -> String {
    let text = composerPromptText
    composerPrompt = TranscriptQuotedPrompt()
    return text
  }

  func restoreComposerPrompt(_ promptText: String) {
    composerPrompt = TranscriptQuotedPrompt(promptText: promptText)
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
