import Foundation
import MarkdownCore
import Testing

struct IncrementalMarkdownParserTests {
  @Test(arguments: [
    "# First\n\nOne **bold** paragraph.\n\nSecond _paragraph_\n---\n\nLast.",
    "Intro\n\n- one\n- two\n\n  continuation\n\n# After\n\nThree",
    "Before\n\n> quote\n>\n> - nested\n\nOutside\n\n```swift\nlet a = 1\n```\n\nEnd",
    "Text\n\n| A | B |\n|---|---|\n| one | two |\n| three | four |\n\nAfter",
    "Title\r\n=====\r\n\r\n👩🏽‍💻 **café** &amp; 日本語\r\n\r\nEnd",
    "[reference]\n\nMiddle\n\n[reference]: https://example.com \"Title\"\n",
    "One\n\nTwo\n\n[link][id]\n\n[id]: /file\n",
    "Before\n\n    indented\n    code\n\nAfter\n\n***\n\nLast",
    "Before\n\n- [ ] task\n  - nested\n\n    ```\n    code\n    ```\n\nEnd",
    "Before\n\n#\n\nAfter\n\n| | |\n|-|-|\n| a | b |\n",
  ])
  func everyPrefixMatchesFullParse(_ document: String) {
    var parser = IncrementalMarkdownParser()
    var source = ""
    for character in document {
      source.append(character)
      #expect(parser.parse(source) == MarkdownParser().parse(source), "Source: \(source)")
    }
  }

  @Test func unchangedPrefixIsExcludedFromParsingAndEditsInvalidateIt() {
    var parser = IncrementalMarkdownParser()
    let prefix = String(repeating: "A paragraph with **style**.\n\n", count: 128)
    _ = parser.parse(prefix + "Tail")
    let source = prefix + "Tail grows"
    #expect(parser.parse(source) == MarkdownParser().parse(source))
    #expect(parser.parsedByteCount == "Tail grows".utf8.count)
    #expect(parser.parse(source) == MarkdownParser().parse(source))
    #expect(parser.parsedByteCount == 0)
    let edited = source.replacingOccurrences(of: "A paragraph", with: "Changed paragraph")
    #expect(parser.parse(edited) == MarkdownParser().parse(edited))
    #expect(parser.parsedByteCount == edited.utf8.count)
  }

  @Test func laterReferenceDefinitionReinterpretsAnEarlierPrefix() {
    var parser = IncrementalMarkdownParser()
    let source = "[later]\n\nAnother paragraph\n\nTail"
    _ = parser.parse(source)
    let defined = source + "\n\n[later]: https://example.com\n"
    #expect(parser.parse(defined) == MarkdownParser().parse(defined))
    #expect(parser.parsedByteCount == defined.utf8.count)
  }

  @Test func generatedContainerTransitionsMatchFullParsing() {
    let lines = [
      "plain **text**", "", "# heading", "---", "===", "- item", "  continuation",
      "> quote", ">", "```swift", "```", "    indented", "| a | b |", "|---|---|",
      "| | |", "***", "~~~", "1. ordered", "[label]", "[label]: /file", "<span>text</span>",
    ]
    var seed: UInt64 = 17
    for _ in 0..<80 {
      var parser = IncrementalMarkdownParser()
      var source = ""
      for _ in 0..<24 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        source += lines[Int(seed >> 32) % lines.count] + "\n"
        #expect(parser.parse(source) == MarkdownParser().parse(source), "Source: \(source)")
      }
    }
  }
}
