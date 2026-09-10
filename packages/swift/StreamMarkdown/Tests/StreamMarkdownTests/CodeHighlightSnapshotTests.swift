import Foundation
import Testing
@testable import StreamMarkdown

struct CodeHighlightSnapshotTests {
  @Test func appendedTextAppearsBeforeHighlightingFinishes() throws {
    let snapshot = CodeHighlightSnapshot(
      source: "let café = 1", language: "swift", themeKey: "dark",
      text: AttributedString("let café = 1")
    )
    let source = "let café = 1\nprint(\"👩🏽‍💻\")"
    let rendered = try #require(snapshot.renderedText(source: source, language: "swift", themeKey: "dark"))
    #expect(String(rendered.characters) == source)
  }

  @Test func replacementLanguageAndThemeRejectOldHighlight() {
    let snapshot = CodeHighlightSnapshot(
      source: "let a = 1", language: "swift", themeKey: "dark", text: AttributedString("let a = 1")
    )
    #expect(snapshot.renderedText(source: "let b = 2", language: "swift", themeKey: "dark") == nil)
    #expect(snapshot.renderedText(source: "let a = 1", language: "swift", themeKey: "light") == nil)
    #expect(snapshot.renderedText(source: "let a = 1", language: "python", themeKey: "dark") == nil)
    #expect(snapshot.renderedText(source: "let a", language: "swift", themeKey: "dark") == nil)
  }
}
