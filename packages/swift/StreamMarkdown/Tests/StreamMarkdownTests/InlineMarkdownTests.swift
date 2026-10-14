import Foundation
import Testing
@testable import StreamMarkdown

@Suite("InlineMarkdown")
struct InlineMarkdownTests {
  @Test("Source-wrapped prose flows through soft breaks", arguments: ["\n", "\r\n"])
  func softBreaksFlowAsSpaces(newline: String) {
    let attributed = inline("First **wrapped\(newline)line** continues.")

    #expect(String(attributed.characters) == "First wrapped line continues.")
    let emphasized = attributed.runs.filter {
      $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
    }
    #expect(emphasized.map { String(attributed[$0.range].characters) }.joined() == "wrapped line")
  }

  @Test("Explicit Markdown hard breaks remain line breaks", arguments: ["  \n", "\\\n"])
  func hardBreaksStayNewlines(separator: String) {
    let attributed = inline("First line\(separator)Second line")

    #expect(String(attributed.characters) == "First line\nSecond line")
    #expect(attributed.runs.contains { $0.inlinePresentationIntent?.contains(.lineBreak) == true })
  }

  @Test("Themed inline code gets chip-tagged runs with padding spaces")
  func codeChip() {
    let attributed = inline("call `foo()` now", theme: .default)
    let hasChip = attributed.runs.contains { run in
      run.inlinePresentationIntent?.contains(.code) == true
        && run[InlineCodeChipAttribute.self] == true
    }
    #expect(hasChip)
    #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
    #expect(String(attributed.characters).contains("\u{202F}foo()\u{202F}"))
    let padsAreTagged = attributed.runs.allSatisfy { run in
      !String(attributed[run.range].characters).contains("\u{202F}")
        || run[InlineCodeChipAttribute.self] == true
    }
    #expect(padsAreTagged)
  }

  @Test("Themed text without code is unchanged")
  func noCodeUnchanged() {
    let attributed = inline("just **words**", theme: .default)
    #expect(String(attributed.characters) == "just words")
    #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
    #expect(attributed.runs.allSatisfy { $0[InlineCodeChipAttribute.self] == nil })
  }

  @Test("Chip pieces group contiguous chip and non-chip runs")
  func chipPieces() {
    let attributed = inline(
      "call `foo()` and **also** `bar`", theme: .default
    )
    let pieces = InlineMarkdown.chipPieces(in: attributed)
    #expect(pieces.map(\.isChip) == [false, true, false, true])
    #expect(String(pieces[0].text.characters) == "call ")
    #expect(String(pieces[1].text.characters) == "\u{202F}foo()\u{202F}")
    #expect(String(pieces[2].text.characters) == " and also ")
    #expect(String(pieces[3].text.characters) == "\u{202F}bar\u{202F}")
    #expect(pieces.map { String($0.text.characters) }.joined() == String(attributed.characters))
  }

  @Test("Chip pieces of chip-free text is one non-chip piece")
  func chipPiecesPlain() {
    let attributed = inline("just **words**", theme: .default)
    let pieces = InlineMarkdown.chipPieces(in: attributed)
    #expect(pieces.map(\.isChip) == [false])
    #expect(String(pieces[0].text.characters) == "just words")
  }

  @Test("Partially-formed emphasis falls back to text")
  func partial() {
    let attributed = inline("an **unfinished")
    #expect(String(attributed.characters).contains("unfinished"))
  }

  @Test("Unsafe link schemes remain non-interactive")
  func unsafeLinks() {
    let attributed = inline("[do not run](javascript:alert(1))")
    #expect(String(attributed.characters) == "do not run")
    #expect(attributed.runs.allSatisfy { $0.link == nil })
  }

  private func inline(_ markdown: String) -> AttributedString {
    InlineMarkdown.attributedString(from: MarkdownParser().parseInline(markdown))
  }

  private func inline(_ markdown: String, theme: MarkdownTheme) -> AttributedString {
    InlineMarkdown.attributedString(from: MarkdownParser().parseInline(markdown), theme: theme)
  }
}
