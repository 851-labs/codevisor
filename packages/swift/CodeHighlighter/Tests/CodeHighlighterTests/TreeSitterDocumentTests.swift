import Foundation
import Testing

@testable import CodeHighlighter

@Suite("Tree-sitter document highlighting")
struct TreeSitterDocumentTests {
  private let theme = """
    {"tokenColors":[
      {"scope":"keyword","settings":{"foreground":"#111111"}},
      {"scope":"comment","settings":{"foreground":"#222222","fontStyle":"italic"}},
      {"scope":"string","settings":{"foreground":"#333333"}},
      {"scope":"constant.numeric","settings":{"foreground":"#444444"}},
      {"scope":"entity.name.function","settings":{"foreground":"#555555","fontStyle":"bold"}},
      {"scope":"variable","settings":{"foreground":"#666666"}},
      {"scope":"support.function.builtin","settings":{"foreground":"#777777"}},
      {"scope":"entity.name.type","settings":{"foreground":"#888888"}}
    ]}
    """

  @Test("All bundled grammars and their queries compile", arguments: SyntaxLanguage.allCases)
  func grammars(language: SyntaxLanguage) throws {
    _ = try TreeSitterGrammar.load(language.rawValue)
  }

  @Test("Incremental patches match a fresh parse through Unicode and multiline edits")
  func editParity() async throws {
    var source = "func café() {\r\n  let emoji = \"☕️ 👩🏽‍💻\"\r\n  return 42\r\n}\r\nfunc other() { return 1 }\r\n"
    let session = CodeHighlightDocument(language: "swift")
    let initial = try await session.update(source: source, themeJSON: theme, revision: 0)
    var applied = render(initial, count: source.utf16.count)
    await session.acknowledge(revision: 0)
    let edits = [
      ("42", "43"), ("emoji", "greeting"), ("☕️ 👩🏽‍💻", "🦀 café"),
      ("return 43", "/* unfinished\nreturn 43"), ("return 43", "comment */ return 43"),
      ("\r\n}", "\r\n  print(greeting)\r\n}"),
    ]
    for (index, replacement) in edits.enumerated() {
      let range = (source as NSString).range(of: replacement.0)
      #expect(range.location != NSNotFound)
      source = (source as NSString).replacingCharacters(in: range, with: replacement.1)
      applied.replaceSubrange(
        range.location..<NSMaxRange(range), with: Array(repeating: .init(), count: replacement.1.utf16.count))
      let update = try await session.update(
        source: source, edits: [.init(range: range, text: replacement.1)],
        themeJSON: theme, revision: index + 1)
      apply(update, to: &applied)
      let fresh = try await CodeHighlightDocument(language: "swift").update(
        source: source, themeJSON: theme, revision: 0)
      #expect(applied == render(fresh, count: source.utf16.count), "Edit \(replacement)")
      await session.acknowledge(revision: index + 1)
    }
  }

  @Test("Small edits do not restyle unrelated top-level functions")
  func boundedInvalidation() async throws {
    let source = (0..<200).map { "func item\($0)() { return \($0) }\n" }.joined()
    let session = CodeHighlightDocument(language: "swift")
    _ = try await session.update(source: source, themeJSON: theme, revision: 0)
    await session.acknowledge(revision: 0)
    let range = (source as NSString).range(of: "return 0")
    let changed = (source as NSString).replacingCharacters(in: range, with: "return 9")
    let result = try await session.update(
      source: changed, edits: [.init(range: range, text: "return 9")], themeJSON: theme, revision: 1)
    #expect(result.invalidatedRange.length < 100)
    #expect(await session.parseCount == 2)
  }

  @Test("Replacing native text storage repaints unchanged text after an external edit")
  func replacedStorageRestoresAllAttributes() async throws {
    let source = "// comment\nfunc first() { return 1 }\nfunc last() { return 2 }"
    let session = CodeHighlightDocument(language: "swift")
    _ = try await session.update(source: source, themeJSON: theme, revision: 0)
    await session.acknowledge(revision: 0)
    let changed = source.replacingOccurrences(of: "return 1", with: "return 9")
    let update = try await session.update(
      source: changed, themeJSON: theme, revision: 1, forceFullHighlight: true)
    let fresh = try await CodeHighlightDocument(language: "swift").update(
      source: changed, themeJSON: theme, revision: 0)
    #expect(update.invalidatedRange == NSRange(location: 0, length: changed.utf16.count))
    #expect(render(update, count: changed.utf16.count) == render(fresh, count: changed.utf16.count))
    #expect(await session.parseCount == 2)
    await session.acknowledge(revision: 1)
    let sameText = try await session.update(
      source: changed, themeJSON: theme, revision: 2, forceFullHighlight: true)
    #expect(sameText.spans == fresh.spans)
    #expect(await session.parseCount == 2)
  }

  @Test("Discarded updates remain dirty until a current revision is acknowledged")
  func discardedUpdate() async throws {
    var source = "func first() { return 1 }\nfunc last() { return 2 }"
    let session = CodeHighlightDocument(language: "swift")
    let initial = try await session.update(source: source, themeJSON: theme, revision: 0)
    var applied = render(initial, count: source.utf16.count)
    await session.acknowledge(revision: 0)
    for (revision, name) in [(1, "first"), (2, "last")] {
      let range = (source as NSString).range(of: name)
      source = (source as NSString).replacingCharacters(in: range, with: "replacement")
      applied.replaceSubrange(range.location..<NSMaxRange(range), with: Array(repeating: .init(), count: 11))
      let result = try await session.update(
        source: source, edits: [.init(range: range, text: "replacement")],
        themeJSON: theme, revision: revision)
      if revision == 2 { apply(result, to: &applied) }
    }
    let fresh = try await CodeHighlightDocument(language: "swift").update(source: source, themeJSON: theme, revision: 0)
    #expect(applied == render(fresh, count: source.utf16.count))
  }

  @Test("A theme change reuses the syntax tree and applies font traits")
  func themeOnlyChange() async throws {
    let session = CodeHighlightDocument(language: "swift")
    let source = "// comment\nfunc greet() {}"
    let first = try await session.update(source: source, themeJSON: theme, revision: 0)
    #expect(first.spans.contains { $0.style.italic })
    #expect(first.spans.contains { $0.style.bold })
    await session.acknowledge(revision: 0)
    let changed = try await session.update(
      source: source, edits: [],
      themeJSON: theme.replacingOccurrences(of: "#111111", with: "#abcdef"), revision: 1)
    #expect(changed.spans.contains { $0.style.foreground == "#abcdef" })
    #expect(await session.parseCount == 1)
  }

  @Test(
    "Markdown and HTML highlight embedded languages",
    arguments: [
      ("markdown", "# Example\n\n```swift\nfunc greet() { return 42 }\n```\n"),
      ("html", "<script>const answer = 42;</script><style>.x { color: red; }</style>"),
    ])
  func injections(sample: (String, String)) async throws {
    let result = try await CodeHighlightDocument(language: sample.0).update(
      source: sample.1, themeJSON: theme, revision: 0)
    let number = (sample.1 as NSString).range(of: "42")
    let styles = render(result, count: sample.1.utf16.count)
    #expect(styles[number.location].foreground == "#444444")
  }

  @Test("Predicate queries distinguish uppercase identifiers and builtin shadowing")
  func predicates() async throws {
    let source = "function example(console) { console.log(Math.PI); }\nconsole.log(1);"
    let result = try await CodeHighlightDocument(language: "javascript").update(
      source: source, themeJSON: theme, revision: 0)
    #expect(!result.spans.isEmpty)
    let grammar = try TreeSitterGrammar.load("javascript")
    let query = try TreeSitterQuery(
      language: grammar.language,
      source: "((identifier) @type (#match? @type \"^[A-Z]\"))", name: "predicate-test")
    let document = try TreeSitterDocument(source: "const lower = Upper;", language: "javascript")
    _ = try document.parse()
    let matches = try query.matches(tree: #require(document.tree), source: document.text.units)
    #expect(matches.count == 1)
    #expect(matches.first?.captures.first?.range == NSRange(location: 14, length: 5))
    let builtinTheme = """
      {"tokenColors":[
        {"scope":"variable.language","settings":{"foreground":"#aaaaaa"}},
        {"scope":"variable.other","settings":{"foreground":"#bbbbbb"}}
      ]}
      """
    let session = CodeHighlightDocument(language: "javascript")
    let initialSource = "let local = 1;\nfunction use() { console.log(local); }"
    let initial = try await session.update(source: initialSource, themeJSON: builtinTheme, revision: 0)
    var applied = render(initial, count: initialSource.utf16.count)
    await session.acknowledge(revision: 0)
    let replacement = "let console = 1;"
    let range = NSRange(location: 0, length: 14)
    let changed = (initialSource as NSString).replacingCharacters(in: range, with: replacement)
    applied.replaceSubrange(0..<14, with: Array(repeating: .init(), count: replacement.utf16.count))
    let patch = try await session.update(
      source: changed, edits: [.init(range: range, text: replacement)],
      themeJSON: builtinTheme, revision: 1)
    apply(patch, to: &applied)
    let fresh = try await CodeHighlightDocument(language: "javascript").update(
      source: changed, themeJSON: builtinTheme, revision: 0)
    #expect(applied == render(fresh, count: changed.utf16.count))
  }

  private func render(_ update: CodeHighlightDocument.Update, count: Int) -> [CodeHighlightDocument.Style] {
    var styles = Array(repeating: CodeHighlightDocument.Style(), count: count)
    apply(update, to: &styles)
    return styles
  }

  private func apply(_ update: CodeHighlightDocument.Update, to styles: inout [CodeHighlightDocument.Style]) {
    for index in update.invalidatedRange.location..<NSMaxRange(update.invalidatedRange) { styles[index] = .init() }
    for span in update.spans {
      for index in span.range.location..<NSMaxRange(span.range) { styles[index] = span.style }
    }
  }
}
