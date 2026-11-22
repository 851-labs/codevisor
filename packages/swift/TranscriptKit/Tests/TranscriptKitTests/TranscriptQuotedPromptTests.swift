import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptQuotedPromptTests {
  private let sentAt = Date(timeIntervalSince1970: 1_793_000_000)
  private let marker = TranscriptQuotedPrompt.quoteMarker

  private func quote(_ text: String, _ messageID: String = "A1") -> TranscriptQuote {
    TranscriptQuote(text: text, messageID: messageID, role: .assistant)
  }

  @Test func quotesReachTheAgentInlineWhereTheyWerePlaced() {
    let prompt = TranscriptQuotedPrompt(
      text: "why does \(marker) conflict with \(marker)?",
      quotes: [
        TranscriptQuote(text: "Use a mutex here.", messageID: "A1", role: .assistant, sentAt: sentAt),
        TranscriptQuote(text: "fix the \"race\"\nin sync", messageID: "B2", role: .user),
      ]
    )

    #expect(
      prompt.promptText == """
        why does <codevisor-quote role="assistant" message="A1" sent="2026-10-26T07:33:20Z">Use a mutex here.\
        </codevisor-quote> conflict with <codevisor-quote role="user" message="B2">fix the "race"
        in sync</codevisor-quote>?
        """)
  }

  @Test func sentPromptReadsBackWithEachQuoteInPlace() {
    let sent = """
      compare <codevisor-quote role="assistant" message="A1" sent="2026-10-26T07:33:20Z">line one

      line two</codevisor-quote> and <codevisor-quote role="user" message="bot-7">second</codevisor-quote> please
      """

    let parsed = TranscriptQuotedPrompt(promptText: sent)

    #expect(parsed.text == "compare \(marker) and \(marker) please")
    #expect(parsed.quotes.map(\.text) == ["line one\n\nline two", "second"])
    #expect(parsed.quotes.map(\.messageID) == ["A1", "bot-7"])
    #expect(parsed.quotes.map(\.role) == [.assistant, .user])
    #expect(parsed.quotes.map(\.sentAt) == [sentAt, nil])
  }

  @Test func earlierQuoteBlocksStillReadAsBadgesBeforeTheText() {
    let legacy = """
      <codevisor-quote role="assistant" message="A1">
      first
      </codevisor-quote>

      <codevisor-quote role="user" message="B2">
      second
      </codevisor-quote>

      Why?
      """

    let parsed = TranscriptQuotedPrompt(promptText: legacy)

    #expect(parsed.text == "\(marker) \(marker)\nWhy?")
    #expect(parsed.quotes.map(\.text) == ["first", "second"])
  }

  @Test func plainOrMalformedPromptsStayUntouched() {
    let plain = "<codevisor-quote> is how quotes look"
    let unclosed = "<codevisor-quote role=\"user\" message=\"A\">never closed"

    for text in [plain, unclosed, "hello"] {
      let parsed = TranscriptQuotedPrompt(promptText: text)
      #expect(parsed.quotes.isEmpty)
      #expect(parsed.text == text)
    }
  }

  @Test func deletingABadgeDropsOnlyItsQuote() {
    let prompt = TranscriptQuotedPrompt(text: "a \(marker) b \(marker) c", quotes: [quote("one"), quote("two")])

    let edited = prompt.replacingCharacters(in: NSRange(location: 2, length: 1), with: TranscriptQuotedPrompt())

    #expect(edited.text == "a  b \(marker) c")
    #expect(edited.quotes.map(\.text) == ["two"])
  }

  @Test func textWithoutItsMarkersCannotKeepTheirQuotes() {
    let prompt = TranscriptQuotedPrompt(text: "no badges left", quotes: [quote("orphan")])
    let strayMarker = TranscriptQuotedPrompt(text: "stray \(marker)", quotes: [])

    #expect(prompt.quotes.isEmpty)
    #expect(strayMarker.text == "stray ")
  }

  @Test func insertedBadgeIsSpacedFromTheWordsAroundIt() {
    let cases: [(text: String, location: Int, expected: String)] = [
      ("", 0, "\(marker) "),
      ("see this", 8, "see this \(marker) "),
      ("see  now", 4, "see \(marker) now"),
      ("seenow", 3, "see \(marker) now"),
    ]

    for (text, location, expected) in cases {
      let prompt = TranscriptQuotedPrompt(text: text)
      let edit = TranscriptQuotedPromptEdit.insertingQuote(quote("q"), into: prompt, at: location)
      #expect(edit.applied(to: prompt).text == expected)
      #expect(edit.applied(to: prompt).quotes.map(\.text) == ["q"])
    }
  }

  @Test func severalQuotesLandTogetherAtTheCaretInOrder() {
    let prompt = TranscriptQuotedPrompt(text: "look end")

    let edit = TranscriptQuotedPromptEdit.insertingQuotes([quote("one"), quote("two")], into: prompt, at: 4)
    let result = edit.applied(to: prompt)

    #expect(result.text == "look \(marker) \(marker) end")
    #expect(result.quotes.map(\.text) == ["one", "two"])
    #expect(edit.selectionAfter.location == ("look \(marker) \(marker)" as NSString).length)
  }

  @Test func userMessagePresentsQuotesInsideItsText() {
    let sent = "typed <codevisor-quote role=\"assistant\" message=\"A1\">quoted</codevisor-quote> after"

    let presented = UserMessage(text: sent).presentingQuotes

    #expect(presented.text == "typed \(marker) after")
    #expect(presented.quotes.map(\.text) == ["quoted"])
    #expect(presented.quotedPrompt.readableText == "typed “quoted” after")
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
