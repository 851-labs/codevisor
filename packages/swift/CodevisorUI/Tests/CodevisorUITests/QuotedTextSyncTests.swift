import AppKit
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorUI

@Suite("Keeping a composer's quotes in step with its text")
@MainActor
struct QuotedTextSyncTests {
  private let marker = TranscriptQuotedPrompt.quoteMarker
  private let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]

  private func quote(_ text: String) -> TranscriptQuote {
    TranscriptQuote(text: text, messageID: "A1", role: .assistant)
  }

  private func storage(showing prompt: TranscriptQuotedPrompt) -> (NSTextStorage, QuotedTextSync) {
    let storage = NSTextStorage(
      attributedString: TranscriptQuoteBadgeText.attributedString(prompt, attributes: attributes))
    let sync = QuotedTextSync()
    sync.observe(storage)
    return (storage, sync)
  }

  private func badges(_ prompt: TranscriptQuotedPrompt) -> NSAttributedString {
    TranscriptQuoteBadgeText.attributedString(prompt, attributes: attributes)
  }

  @Test func typingAroundBadgesKeepsEachQuoteInPlace() {
    let (storage, sync) = storage(showing: TranscriptQuotedPrompt(text: "a \(marker) b", quotes: [quote("one")]))

    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "start ")
    storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: " end")

    let prompt = sync.prompt(of: storage)
    #expect(prompt.text == "start a \(marker) b end")
    #expect(prompt.quotes.map(\.text) == ["one"])
  }

  @Test func deletingABadgeDropsOnlyThatQuote() {
    let (storage, sync) = storage(
      showing: TranscriptQuotedPrompt(text: "\(marker) and \(marker)", quotes: [quote("one"), quote("two")]))

    storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")

    #expect(sync.prompt(of: storage).quotes.map(\.text) == ["two"])
  }

  @Test func restoringADeletedBadgeBringsItsQuoteBack() {
    let (storage, sync) = storage(showing: TranscriptQuotedPrompt(text: "see \(marker)", quotes: [quote("one")]))
    let removed = storage.attributedSubstring(from: NSRange(location: 4, length: 1))

    storage.replaceCharacters(in: NSRange(location: 4, length: 1), with: "")
    #expect(sync.prompt(of: storage).quotes.isEmpty)
    storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: removed)

    #expect(sync.prompt(of: storage).quotes.map(\.text) == ["one"])
  }

  @Test func insertingBadgesMidTextOrdersQuotesByPosition() {
    let (storage, sync) = storage(showing: TranscriptQuotedPrompt(text: "x \(marker) y", quotes: [quote("later")]))

    storage.replaceCharacters(
      in: NSRange(location: 0, length: 0),
      with: badges(TranscriptQuotedPrompt(text: marker, quotes: [quote("earlier")])))

    #expect(sync.prompt(of: storage).quotes.map(\.text) == ["earlier", "later"])
  }

  @Test func aPastedPlaceholderWithoutABadgeIsNotTreatedAsAQuote() {
    let (storage, sync) = storage(showing: TranscriptQuotedPrompt(text: "hi"))

    storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: " \(marker)")

    let prompt = sync.prompt(of: storage)
    #expect(prompt.text == "hi ")
    #expect(prompt.quotes.isEmpty)
  }
}
