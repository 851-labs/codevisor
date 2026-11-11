import Foundation
import MarkdownCore
import SwiftUI
import Testing

@testable import StreamMarkdown

@MainActor
struct StreamingMarkdownTailCompletionTests {
  private static let sentence =
    "Turn 4 sentence 2: the layout pass touches **runway** state, calls `reconcile()`, and links to "
    + "[docs 2](https://example.com/4/2) with emoji 🚀 and ~~old~~ text."

  @Test("Streamed text never shows unfinished markup and only ever grows")
  func everyPrefixRendersAPrefixOfTheFinalText() {
    var parser = IncrementalMarkdownParser()
    let final = Self.plainText(MarkdownParser().parse(Self.sentence))
    var source = ""
    for character in Self.sentence {
      source.append(character)
      let shown = Self.plainText(parser.parse(source, completingOpenTail: true))
      #expect(final.hasPrefix(shown), "Source: \(source) shown: \(shown)")
    }
  }

  @Test("A finished message parses its exact markdown")
  func settledTextIsNotCompleted() {
    var parser = IncrementalMarkdownParser()
    let source = "Ends with an unfinished [link"
    _ = parser.parse(source, completingOpenTail: true)

    #expect(parser.parse(source) == MarkdownParser().parse(source))
  }

  @Test("An unfinished image is hidden until it is complete")
  func partialImageIsHidden() {
    var parser = IncrementalMarkdownParser()

    #expect(Self.plainText(parser.parse("See ![shot](./media/a.p", completingOpenTail: true)) == "See")
  }

  @Test("Text inside an open code fence is left alone")
  func openFenceIsUnchanged() {
    var parser = IncrementalMarkdownParser()
    let source = "Intro\n\n```swift\nlet value = items[0"

    #expect(parser.parse(source, completingOpenTail: true) == MarkdownParser().parse(source))
  }

  @Test("Brackets inside words are not treated as links")
  func subscriptsStayLiteral() {
    var parser = IncrementalMarkdownParser()
    let source = "Read array[0"

    #expect(parser.parse(source, completingOpenTail: true) == MarkdownParser().parse(source))
  }

  @Test(
    "Unfinished markup in tricky spots never shows stray markers",
    arguments: [
      "Use `C:\\` then **bold text** and more.",
      "This is **really important** stuff.",
      "Check [ ] boxes and [1] footnotes and [docs](https://example.com) links.",
    ])
  func trickyPrefixesRenderPrefixesOfTheFinalText(_ document: String) {
    var parser = IncrementalMarkdownParser()
    let final = Self.plainText(MarkdownParser().parse(document))
    var source = ""
    for character in document {
      source.append(character)
      let shown = Self.plainText(parser.parse(source, completingOpenTail: true))
      #expect(final.hasPrefix(shown) || shown.isEmpty, "Source: \(source) shown: \(shown)")
    }
  }

  @MainActor
  private static func plainText(_ blocks: [MarkdownBlock]) -> String {
    guard !blocks.isEmpty else { return "" }

    return MarkdownTextRunRenderer.attributedString(for: blocks, theme: .default, foregroundColor: .primary).string
      .trimmingCharacters(in: .whitespaces)
  }
}
