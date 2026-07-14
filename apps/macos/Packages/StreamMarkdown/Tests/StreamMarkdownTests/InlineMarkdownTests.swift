import Foundation
import Testing
@testable import StreamMarkdown

@Suite("InlineMarkdown")
struct InlineMarkdownTests {
    @Test("Renders bold emphasis as a strong run")
    func bold() {
        let attributed = InlineMarkdown.attributedString(from: "This is **bold** text")
        let hasStrong = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(hasStrong)
        #expect(String(attributed.characters).contains("bold"))
    }

    @Test("Renders inline code")
    func code() {
        let attributed = InlineMarkdown.attributedString(from: "call `foo()` now")
        let hasCode = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
        }
        #expect(hasCode)
    }

    @Test("Themed inline code gets chip-tagged runs with padding spaces")
    func codeChip() {
        let attributed = InlineMarkdown.attributedString(from: "call `foo()` now", theme: .default)
        let hasChip = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
                && run[InlineCodeChipAttribute.self] == true
        }
        #expect(hasChip)
        // The chip background is painted by the TextKit layout manager
        // (rounded corners), never by the square-only backgroundColor attribute.
        #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
        // Narrow no-break spaces pad each side of the code span; the pads are
        // chip-tagged too so the pill covers them.
        #expect(String(attributed.characters).contains("\u{202F}foo()\u{202F}"))
        let padsAreTagged = attributed.runs.allSatisfy { run in
            !String(attributed[run.range].characters).contains("\u{202F}")
                || run[InlineCodeChipAttribute.self] == true
        }
        #expect(padsAreTagged)
    }

    @Test("Themed text without code is unchanged")
    func noCodeUnchanged() {
        let attributed = InlineMarkdown.attributedString(from: "just **words**", theme: .default)
        #expect(String(attributed.characters) == "just words")
        #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
        #expect(attributed.runs.allSatisfy { $0[InlineCodeChipAttribute.self] == nil })
    }

    @Test("Chip pieces group contiguous chip and non-chip runs")
    func chipPieces() {
        let attributed = InlineMarkdown.attributedString(
            from: "call `foo()` and **also** `bar`", theme: .default
        )
        let pieces = InlineMarkdown.chipPieces(in: attributed)
        #expect(pieces.map(\.isChip) == [false, true, false, true])
        #expect(String(pieces[0].text.characters) == "call ")
        #expect(String(pieces[1].text.characters) == "\u{202F}foo()\u{202F}")
        // The bold span stays merged into the surrounding non-chip piece even
        // though it is a separate attribute run.
        #expect(String(pieces[2].text.characters) == " and also ")
        #expect(String(pieces[3].text.characters) == "\u{202F}bar\u{202F}")
        // Re-joining the pieces reproduces the source text exactly.
        #expect(pieces.map { String($0.text.characters) }.joined() == String(attributed.characters))
    }

    @Test("Chip pieces of chip-free text is one non-chip piece")
    func chipPiecesPlain() {
        let attributed = InlineMarkdown.attributedString(from: "just **words**", theme: .default)
        let pieces = InlineMarkdown.chipPieces(in: attributed)
        #expect(pieces.map(\.isChip) == [false])
        #expect(String(pieces[0].text.characters) == "just words")
    }

    @Test("Plain text passes through unchanged")
    func plain() {
        let attributed = InlineMarkdown.attributedString(from: "just words")
        #expect(String(attributed.characters) == "just words")
    }

    @Test("Partially-formed emphasis falls back to text")
    func partial() {
        // A dangling opening marker should not crash and should keep the text.
        let attributed = InlineMarkdown.attributedString(from: "an **unfinished")
        #expect(String(attributed.characters).contains("unfinished"))
    }
}
