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
