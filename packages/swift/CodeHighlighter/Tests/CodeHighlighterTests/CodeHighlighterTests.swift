import Foundation
import Testing

@testable import CodeHighlighter
import CodevisorTheming

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
            { "scope": "comment", "settings": { "foreground": "#6272a4" } },
            { "scope": "string", "settings": { "foreground": "#f1fa8c" } },
            { "scope": "constant.numeric", "settings": { "foreground": "#bd93f9" } },
            { "scope": "variable.other.property", "settings": { "foreground": "#50fa7b" } },
            { "scope": "entity.name.tag", "settings": { "foreground": "#ff5555" } },
            { "scope": "markup.inserted", "settings": { "foreground": "#50fa7b" } }
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

    @Test("Changing a theme document invalidates settled colors")
    func editedThemeInvalidatesCache() async throws {
        let highlighter = CodeHighlighter()
        let firstTheme = """
            {"tokenColors":[{"scope":"keyword","settings":{"foreground":"#111111"}}]}
            """
        let secondTheme = """
            {"tokenColors":[{"scope":"keyword","settings":{"foreground":"#abcdef"}}]}
            """

        let first = try #require(
            await highlighter.highlight(
                code: "let value = 1", language: "swift",
                themeKey: "editable-theme", themeJSON: firstTheme))
        let second = try #require(
            await highlighter.highlight(
                code: "let value = 1", language: "swift",
                themeKey: "editable-theme", themeJSON: secondTheme))

        #expect(first[0].first?.color == "#111111")
        #expect(second[0].first?.color == "#abcdef")
    }

    @Test("Every previously bundled language remains supported")
    func supportedLanguages() async throws {
        let samples: [String: String] = [
            "bash": "if true; then echo ok; fi",
            "c": "int main(void) { return 0; }",
            "cpp": "class Widget { public: void run(); };",
            "css": ".card { color: red; }",
            "diff": "+let added = true",
            "go": "func main() { return }",
            "html": "<button disabled>Go</button>",
            "java": "class Main { static void run() {} }",
            "javascript": "const answer = () => 42",
            "json": "{\"answer\": 42}",
            "jsx": "const view = <Button title=\"Go\" />",
            "kotlin": "fun main() = println(42)",
            "markdown": "# Heading\n`code`",
            "python": "def main():\n    return 42",
            "ruby": "def main\n  42\nend",
            "rust": "fn main() { let value = 42; }",
            "sql": "SELECT value FROM records WHERE id = 42",
            "swift": "func main() -> Int { 42 }",
            "toml": "enabled = true",
            "tsx": "const view: ReactNode = <Button />",
            "typescript": "interface User { name: string }",
            "yaml": "enabled: true",
        ]
        let highlighter = CodeHighlighter()

        for (language, code) in samples {
            let tokens = try #require(
                await highlighter.highlight(
                    code: code,
                    language: language,
                    themeKey: "test-theme",
                    themeJSON: themeJSON
                ),
                "Missing native lexer for \(language)"
            )
            #expect(join(tokens) == code, "Native lexer changed \(language) source")
        }
    }

    @Test("Streaming line-state reuse matches a fresh final highlight")
    func streamingParity() async throws {
        let streaming = CodeHighlighter()
        _ = await streaming.highlight(
            code: "/* start\n still",
            language: "swift",
            themeKey: "test-theme",
            themeJSON: themeJSON,
            sessionID: "message.code.0",
            isComplete: false
        )
        let incremental = try #require(
            await streaming.highlight(
                code: "/* start\n still comment */\nfunc greet() { return 1 }",
                language: "swift",
                themeKey: "test-theme",
                themeJSON: themeJSON,
                sessionID: "message.code.0",
                isComplete: true
            ))
        let fresh = try #require(
            await CodeHighlighter().highlight(
                code: "/* start\n still comment */\nfunc greet() { return 1 }",
                language: "swift",
                themeKey: "test-theme",
                themeJSON: themeJSON
            ))
        #expect(incremental == fresh)
        #expect(incremental[1].first?.color?.lowercased() == "#6272a4")
    }

    @Test("Preserves Unicode, CRLF, and a trailing empty line")
    func exactSourceRoundTrip() async throws {
        let code = "let café = \"☕️\"\r\nprint(café)\r\n"
        let tokens = try #require(
            await CodeHighlighter().highlight(
                code: code,
                language: "swift",
                themeKey: "test-theme",
                themeJSON: themeJSON
            ))
        #expect(tokens.count == 3)
        #expect(join(tokens) == code)
    }

    @Test("Language-specific TextMate selectors beat generic rules")
    func selectorSpecificity() async throws {
        let theme = """
            {
              "tokenColors": [
                { "scope": "keyword", "settings": { "foreground": "#111111" } },
                { "scope": "source.swift storage.type.function", "settings": { "foreground": "#abcdef" } }
              ]
            }
            """
        let tokens = try #require(
            await CodeHighlighter().highlight(
                code: "func greet() {}",
                language: "swift",
                themeKey: "specificity",
                themeJSON: theme
            ))
        let functionKeyword = tokens[0].first { $0.content.contains("func") }
        #expect(functionKeyword?.color?.lowercased() == "#abcdef")
    }

    @Test("Styles properties, tags, and diff additions")
    func representativeCaptures() async throws {
        let highlighter = CodeHighlighter()
        let json = try #require(
            await highlighter.highlight(
                code: "{\"answer\": 42}", language: "json",
                themeKey: "test-theme", themeJSON: themeJSON))
        #expect(json[0].contains { $0.content.contains("answer") && $0.color == "#50fa7b" })

        let html = try #require(
            await highlighter.highlight(
                code: "<button>Go</button>", language: "html",
                themeKey: "test-theme", themeJSON: themeJSON))
        #expect(html[0].contains { $0.content == "button" && $0.color == "#ff5555" })

        let diff = try #require(
            await highlighter.highlight(
                code: "+added", language: "diff",
                themeKey: "test-theme", themeJSON: themeJSON))
        #expect(diff[0].first?.color == "#50fa7b")
    }

    @MainActor
    @Test("Every bundled app theme produces useful native colors")
    func bundledThemeCompatibility() async throws {
        let catalog = ThemeCatalog(
            customThemesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("codevisor-highlighter-theme-tests")
        )
        let highlighter = CodeHighlighter()
        let code = """
            // A representative palette sample
            struct Greeting {
                let count = 42
                func text() -> String { "hello \\(count)" }
            }
            """

        for descriptor in catalog.availableThemes
        where !ThemeCatalog.isSystemTheme(id: descriptor.id) {
            let data = try catalog.loadThemeData(id: descriptor.id)
            let json = try #require(String(data: data, encoding: .utf8))
            let lines = try #require(
                await highlighter.highlight(
                    code: code,
                    language: "swift",
                    themeKey: descriptor.id,
                    themeJSON: json
                ),
                "Theme \(descriptor.id) failed native highlighting"
            )
            let colors = Set(lines.flatMap { $0 }.compactMap(\.color))
            #expect(colors.count >= 2, "Theme \(descriptor.id) produced too few syntax colors")
        }
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

    private func join(_ lines: [[CodeHighlighter.Token]]) -> String {
        lines.map { $0.map(\.content).joined() }.joined(separator: "\n")
    }
}
