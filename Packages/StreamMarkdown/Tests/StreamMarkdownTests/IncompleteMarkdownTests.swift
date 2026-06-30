import Foundation
import Testing
@testable import StreamMarkdown

@Suite("IncompleteMarkdown")
struct IncompleteMarkdownTests {
    @Test("Detects an unclosed code fence")
    func unclosedFence() {
        #expect(IncompleteMarkdown.hasUnclosedCodeFence("```swift\nlet x = 1"))
        #expect(!IncompleteMarkdown.hasUnclosedCodeFence("```swift\nlet x = 1\n```"))
        #expect(!IncompleteMarkdown.hasUnclosedCodeFence("no fences here"))
    }

    @Test("Closing fence must match the opening character and length")
    func fenceMatching() {
        // Tilde does not close a backtick fence.
        #expect(IncompleteMarkdown.hasUnclosedCodeFence("```\ncode\n~~~"))
        // A longer closing fence is allowed.
        #expect(!IncompleteMarkdown.hasUnclosedCodeFence("```\ncode\n`````"))
        // A shorter run does not close.
        #expect(IncompleteMarkdown.hasUnclosedCodeFence("````\ncode\n```"))
    }

    @Test("Indented fences up to three spaces count; four does not")
    func indentation() {
        #expect(IncompleteMarkdown.hasUnclosedCodeFence("   ```\ncode"))
        #expect(!IncompleteMarkdown.hasUnclosedCodeFence("    ```\ncode"))
    }

    @Test("Detects an incomplete table header")
    func incompleteTable() {
        #expect(IncompleteMarkdown.hasIncompleteTable("| Name | Age |"))
        // A delimiter row is not an incomplete header.
        #expect(!IncompleteMarkdown.hasIncompleteTable("| --- | --- |"))
        // No pipe, no table.
        #expect(!IncompleteMarkdown.hasIncompleteTable("just text"))
    }

    @Test("Identifies delimiter rows")
    func delimiterRows() {
        #expect(IncompleteMarkdown.isDelimiterRow(Substring("| --- | :--: |")))
        #expect(IncompleteMarkdown.isDelimiterRow(Substring(":---:")))
        #expect(!IncompleteMarkdown.isDelimiterRow(Substring("| Name |")))
        #expect(!IncompleteMarkdown.isDelimiterRow(Substring("plain")))
    }

    @Test("fenceRun returns nil for non-fence lines")
    func fenceRunNil() {
        #expect(IncompleteMarkdown.fenceRun(in: Substring("text")) == nil)
        #expect(IncompleteMarkdown.fenceRun(in: Substring("``")) == nil) // only two backticks
        #expect(IncompleteMarkdown.fenceRun(in: Substring("")) == nil)
    }
}
