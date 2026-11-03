import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptQuotedPromptTests {
  private let sentAt = Date(timeIntervalSince1970: 1_793_000_000)

  @Test func quotesReachTheAgentAsMarkedBlocksBeforeTheMessage() {
    let prompt = TranscriptQuotedPrompt(
      quotes: [
        TranscriptQuote(text: "Use a mutex here.", messageID: "A1", role: .assistant, sentAt: sentAt),
        TranscriptQuote(text: "fix the \"race\"\nin sync", messageID: "B2", role: .user),
      ],
      text: "Why?"
    )

    #expect(
      prompt.promptText == """
        <codevisor-quote role="assistant" message="A1" sent="2026-10-26T07:33:20Z">
        Use a mutex here.
        </codevisor-quote>

        <codevisor-quote role="user" message="B2">
        fix the "race"
        in sync
        </codevisor-quote>

        Why?
        """)
  }

  @Test func sentPromptSplitsBackIntoQuotesAndTypedText() {
    let quotes = [
      TranscriptQuote(text: "line one\n\nline two", messageID: "A1", role: .assistant, sentAt: sentAt),
      TranscriptQuote(text: "second", messageID: "bot-7", role: .user),
    ]
    let sent = TranscriptQuotedPrompt(quotes: quotes, text: "Explain both").promptText

    let parsed = TranscriptQuotedPrompt(promptText: sent)

    #expect(parsed.text == "Explain both")
    #expect(parsed.quotes.map(\.text) == ["line one\n\nline two", "second"])
    #expect(parsed.quotes.map(\.messageID) == ["A1", "bot-7"])
    #expect(parsed.quotes.map(\.role) == [.assistant, .user])
    #expect(parsed.quotes.map(\.sentAt) == [sentAt, nil])
  }

  @Test func quoteOnlyPromptHasNoTypedText() {
    let sent = TranscriptQuotedPrompt(
      quotes: [TranscriptQuote(text: "just this", messageID: "A1", role: .assistant)], text: ""
    ).promptText

    #expect(!sent.hasSuffix("\n\n"))
    #expect(TranscriptQuotedPrompt(promptText: sent).text == "")
  }

  @Test func plainOrMalformedPromptsStayUntouched() {
    let plain = "<codevisor-quote> is how quotes look"
    let unclosed = "<codevisor-quote role=\"user\" message=\"A\">\nnever closed"

    for text in [plain, unclosed, "hello"] {
      let parsed = TranscriptQuotedPrompt(promptText: text)
      #expect(parsed.quotes.isEmpty)
      #expect(parsed.text == text)
    }
  }

  @Test func userMessagePresentsQuotesAsChipsAndKeepsTypedText() {
    let sent = TranscriptQuotedPrompt(
      quotes: [TranscriptQuote(text: "quoted", messageID: "A1", role: .assistant)], text: "typed"
    ).promptText

    let presented = UserMessage(text: sent).presentingQuotes

    #expect(presented.text == "typed")
    #expect(presented.quotes.map(\.text) == ["quoted"])
  }

  @Test func quoteSourceMatchesEveryRowOfItsMessage() {
    let id = "3F2A6C1E-0000-4000-8000-000000000001"
    let quote = TranscriptQuote(text: "x", messageID: id, role: .assistant)

    #expect(quote.isSource(ofRowKey: "message:\(id)"))
    #expect(quote.isSource(ofRowKey: "message:\(id):markdown:text:0"))
    #expect(!quote.isSource(ofRowKey: "message:3F2A6C1E-0000-4000-8000-000000000002"))
    #expect(TranscriptQuote.messageID(forRowKey: "bot:msg_42") == "msg_42")
    #expect(TranscriptQuote.messageID(forRowKey: "setup") == nil)
  }

  @Test func snippetCollapsesWhitespaceAndTruncates() {
    let long = TranscriptQuote(text: String(repeating: "word ", count: 40), messageID: "A", role: .user)
    let short = TranscriptQuote(text: "  two\n\nlines ", messageID: "A", role: .user)

    #expect(short.snippet == "two lines")
    #expect(long.snippet.hasSuffix("…"))
    #expect(long.snippet.count <= 81)
  }
}
