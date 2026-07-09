import Foundation
import Testing

@testable import CodeHighlighter

@Suite("CodeHighlighter")
struct CodeHighlighterTests {
    // A minimal but valid Shiki theme: dark bg, pink keywords.
    private let themeJSON = """
        {
          "name": "test-theme",
          "type": "dark",
          "colors": { "editor.background": "#1e1e2e", "editor.foreground": "#cdd6f4" },
          "tokenColors": [
            { "scope": ["keyword", "storage"], "settings": { "foreground": "#ff79c6" } },
            { "scope": "comment", "settings": { "foreground": "#6272a4" } }
          ]
        }
        """

    @Test("Highlights Swift keywords with theme colors")
    func swiftHighlighting() async throws {
        let highlighter = CodeHighlighter()
        let tokens = try #require(
            await highlighter.highlight(
                code: "// hi\nfunc greet() {}",
                language: "swift",
                themeKey: "test-theme",
                themeJSON: themeJSON
        ))
        #expect(tokens.count == 2)
        #expect(tokens[0].map(\.content).joined() == "// hi")
        // `func` is a keyword.
        let funcToken = tokens[1].first { $0.content.contains("func") }
        #expect(funcToken?.color?.lowercased() == "#ff79c6")
        // Round-trip content equals the input.
        let joined = tokens.map { $0.map(\.content).joined() }.joined(separator: "\n")
        #expect(joined == "// hi\nfunc greet() {}")
    }

    @Test("Unknown languages and empty language return nil")
    func unknownLanguage() async {
        let highlighter = CodeHighlighter()
        let unknown = await highlighter.highlight(
            code: "x", language: "klingon", themeKey: "t", themeJSON: themeJSON)
        #expect(unknown == nil)
        let missing = await highlighter.highlight(
            code: "x", language: nil, themeKey: "t", themeJSON: themeJSON)
        #expect(missing == nil)
    }

    @Test("Aliases resolve and results cache")
    func aliasesAndCache() async throws {
        let highlighter = CodeHighlighter()
        let first = try #require(
            await highlighter.highlight(
                code: "const x = 1", language: "ts", themeKey: "t", themeJSON: themeJSON))
        let second = try #require(
            await highlighter.highlight(
                code: "const x = 1", language: "ts", themeKey: "t", themeJSON: themeJSON))
        #expect(first == second)
    }

    @Test("File paths map to bundled grammar names")
    func languageForPath() {
        #expect(CodeHighlighter.language(forPath: "Features/Session/DiffView.swift") == "swift")
        #expect(CodeHighlighter.language(forPath: "src/main.rs") == "rust")
        #expect(CodeHighlighter.language(forPath: "types.d.ts") == "typescript")
        #expect(CodeHighlighter.language(forPath: "App.tsx") == "tsx")
        #expect(CodeHighlighter.language(forPath: "include/foo.hpp") == "cpp")
        #expect(CodeHighlighter.language(forPath: "CONFIG.YML") == "yaml")
        #expect(CodeHighlighter.language(forPath: "scripts/build.mjs") == "javascript")
        // No extension or no bundled grammar → nil, caller keeps plain text.
        #expect(CodeHighlighter.language(forPath: "Makefile") == nil)
        #expect(CodeHighlighter.language(forPath: "photo.jpeg") == nil)
    }
}
