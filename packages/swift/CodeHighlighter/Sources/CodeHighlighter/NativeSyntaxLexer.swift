import Foundation

// Language profiles are intentionally co-located with the scanner so every
// supported fence and its lexical behavior can be audited in one place.
// swiftlint:disable file_length

enum SyntaxLanguage: String, CaseIterable, Sendable {
  case bash, c, cpp, css, diff, go, html, java, javascript, json, jsx, kotlin
  case markdown, python, ruby, rust, sql, swift, toml, tsx, typescript, yaml

  static func resolve(_ value: String?) -> SyntaxLanguage? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let language = SyntaxLanguage(rawValue: normalized) { return language }
    return aliases[normalized]
  }

  private static let aliases: [String: SyntaxLanguage] = [
    "js": .javascript, "mjs": .javascript, "cjs": .javascript,
    "ts": .typescript, "mts": .typescript, "cts": .typescript,
    "py": .python, "rb": .ruby, "golang": .go, "kt": .kotlin,
    "md": .markdown, "sh": .bash, "shell": .bash, "zsh": .bash,
    "yml": .yaml, "c++": .cpp, "jsonc": .json, "patch": .diff,
  ]

  var textMateRootScope: String {
    switch self {
    case .bash: "source.shell"
    case .c: "source.c"
    case .cpp: "source.cpp"
    case .css: "source.css"
    case .diff: "source.diff"
    case .go: "source.go"
    case .html: "text.html.basic"
    case .java: "source.java"
    case .javascript: "source.js"
    case .json: "source.json"
    case .jsx: "source.js.jsx"
    case .kotlin: "source.kotlin"
    case .markdown: "text.html.markdown"
    case .python: "source.python"
    case .ruby: "source.ruby"
    case .rust: "source.rust"
    case .sql: "source.sql"
    case .swift: "source.swift"
    case .toml: "source.toml"
    case .tsx: "source.tsx"
    case .typescript: "source.ts"
    case .yaml: "source.yaml"
    }
  }

  var lineComments: [String] {
    switch self {
    case .bash, .python, .ruby, .toml, .yaml: ["#"]
    case .sql: ["--"]
    case .c, .cpp, .css, .go, .java, .javascript, .jsx, .kotlin, .rust, .swift,
      .tsx, .typescript:
      ["//"]
    case .json: []
    case .diff, .html, .markdown: []
    }
  }

  var blockComment: (start: String, end: String)? {
    switch self {
    case .c, .cpp, .css, .go, .java, .javascript, .jsx, .kotlin, .rust, .sql,
      .swift, .tsx, .typescript:
      ("/*", "*/")
    default: nil
    }
  }

  var quotes: Set<UInt8> {
    switch self {
    case .json: [34]
    case .bash, .javascript, .jsx, .sql, .tsx, .typescript: [34, 39, 96]
    case .diff, .html, .markdown: []
    default: [34, 39]
    }
  }

  var multilineStrings: [String] {
    switch self {
    case .python, .swift, .kotlin: ["\"\"\"", "'''"]
    case .javascript, .jsx, .tsx, .typescript, .bash: ["`"]
    default: []
    }
  }

  var isPropertyLanguage: Bool {
    switch self {
    case .css, .json, .toml, .yaml: true
    default: false
    }
  }

  func capture(for word: String) -> String? {
    let key = self == .sql ? word.lowercased() : word
    if Self.functionKeywords[self, default: []].contains(key) { return "keyword.function" }
    if Self.typeKeywords[self, default: []].contains(key) { return "keyword.type" }
    if Self.returnKeywords.contains(key) { return "keyword.return" }
    if Self.importKeywords.contains(key) { return "keyword.import" }
    if Self.keywords[self, default: []].contains(key) { return "keyword" }
    if Self.builtinTypes[self, default: []].contains(key) { return "type.builtin" }
    if Self.booleans.contains(key.lowercased()) { return "boolean" }
    if Self.constants.contains(key) || Self.constants.contains(key.lowercased()) {
      return "constant"
    }
    return nil
  }

  func declarationCapture(after word: String) -> String? {
    let key = self == .sql ? word.lowercased() : word
    if Self.functionKeywords[self, default: []].contains(key) { return "function" }
    if Self.typeKeywords[self, default: []].contains(key) { return "type" }
    return nil
  }

  private static let returnKeywords: Set<String> = [
    "return", "yield", "throw", "throws", "rethrows", "raise", "break", "continue",
  ]
  private static let importKeywords: Set<String> = [
    "import", "include", "require", "from", "using", "package", "module", "export",
  ]
  private static let booleans: Set<String> = ["true", "false", "yes", "no", "on", "off"]
  private static let constants: Set<String> = [
    "nil", "null", "none", "undefined", "self", "Self", "super", "this", "NULL",
  ]

  private static let functionKeywords: [SyntaxLanguage: Set<String>] = [
    .bash: ["function"], .go: ["func"], .javascript: ["function"], .jsx: ["function"],
    .kotlin: ["fun"], .python: ["def", "lambda"], .ruby: ["def"], .rust: ["fn"],
    .swift: ["func", "init", "deinit", "subscript"], .tsx: ["function"],
    .typescript: ["function"],
  ]

  private static let typeKeywords: [SyntaxLanguage: Set<String>] = [
    .c: ["enum", "struct", "typedef", "union"],
    .cpp: ["class", "concept", "enum", "struct", "template", "typedef", "typename", "union"],
    .go: ["interface", "struct", "type"],
    .java: ["class", "enum", "interface", "record"],
    .javascript: ["class"], .jsx: ["class"],
    .kotlin: ["class", "data", "enum", "interface", "object", "typealias"],
    .python: ["class"], .ruby: ["class", "module"],
    .rust: ["enum", "struct", "trait", "type"],
    .swift: ["actor", "class", "enum", "extension", "protocol", "struct", "typealias"],
    .tsx: ["class", "enum", "interface", "type"],
    .typescript: ["class", "enum", "interface", "type"],
  ]

  private static let builtinTypes: [SyntaxLanguage: Set<String>] = [
    .c: ["_Bool", "char", "double", "float", "int", "long", "short", "signed", "unsigned", "void"],
    .cpp: ["bool", "char", "double", "float", "int", "long", "short", "signed", "unsigned", "void", "wchar_t"],
    .go: [
      "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32",
      "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
    ],
    .java: ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void", "String"],
    .javascript: ["Array", "BigInt", "Boolean", "Map", "Number", "Object", "Promise", "Set", "String"],
    .jsx: ["Array", "Boolean", "Number", "Object", "Promise", "String"],
    .kotlin: [
      "Any", "Boolean", "Byte", "Char", "Double", "Float", "Int", "Long", "Nothing", "Short", "String", "Unit",
    ],
    .python: ["bool", "bytes", "dict", "float", "int", "list", "object", "set", "str", "tuple"],
    .rust: [
      "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8", "u16", "u32", "u64",
      "u128", "usize",
    ],
    .swift: ["Any", "AnyObject", "Bool", "Character", "Double", "Float", "Int", "Never", "String", "UInt", "Void"],
    .tsx: ["any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown", "void"],
    .typescript: ["any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown", "void"],
  ]

  private static let keywords: [SyntaxLanguage: Set<String>] = [
    .bash: [
      "case", "coproc", "do", "done", "elif", "else", "esac", "fi", "for", "if", "in", "select", "then", "time",
      "until", "while",
    ],
    .c: [
      "auto", "case", "const", "default", "do", "else", "extern", "for", "goto", "if", "inline", "register",
      "restrict", "sizeof", "static", "switch", "volatile", "while",
    ],
    .cpp: [
      "alignas", "alignof", "asm", "case", "catch", "const", "constexpr", "consteval", "constinit", "decltype",
      "default", "delete", "do", "else", "explicit", "extern", "for", "friend", "if", "mutable", "namespace",
      "new", "noexcept", "operator", "override", "private", "protected", "public", "requires", "sizeof", "static",
      "switch", "thread_local", "try", "virtual", "while",
    ],
    .css: ["important", "media", "supports"],
    .go: [
      "case", "chan", "const", "default", "defer", "else", "fallthrough", "for", "go", "goto", "if", "map",
      "range", "select", "switch", "var",
    ],
    .java: [
      "abstract", "assert", "case", "catch", "const", "default", "do", "else", "extends", "final", "finally",
      "for", "if", "implements", "instanceof", "native", "new", "private", "protected", "public", "static",
      "strictfp", "switch", "synchronized", "transient", "try", "var", "volatile", "while",
    ],
    .javascript: [
      "as", "async", "await", "case", "catch", "const", "debugger", "default", "delete", "do", "else", "extends",
      "finally", "for", "get", "if", "in", "instanceof", "let", "new", "of", "set", "static", "switch", "try",
      "typeof", "var", "while", "with",
    ],
    .jsx: [
      "as", "async", "await", "case", "catch", "const", "default", "delete", "else", "extends", "finally", "for",
      "if", "in", "instanceof", "let", "new", "of", "static", "switch", "try", "typeof", "var", "while",
    ],
    .kotlin: [
      "as", "by", "catch", "companion", "const", "constructor", "crossinline", "do", "else", "field", "file",
      "final", "finally", "for", "get", "if", "in", "infix", "inline", "inner", "is", "lateinit", "noinline",
      "open", "operator", "out", "override", "private", "protected", "public", "reified", "sealed", "set",
      "suspend", "tailrec", "try", "val", "var", "vararg", "when", "where", "while",
    ],
    .python: [
      "and", "as", "assert", "async", "await", "case", "del", "elif", "else", "except", "finally", "for",
      "global", "if", "in", "is", "match", "nonlocal", "not", "or", "pass", "try", "while", "with",
    ],
    .ruby: [
      "alias", "and", "begin", "case", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "next", "not",
      "or", "redo", "rescue", "retry", "then", "unless", "until", "when", "while",
    ],
    .rust: [
      "as", "async", "await", "const", "crate", "dyn", "else", "extern", "for", "if", "impl", "in", "let", "loop",
      "match", "mod", "move", "mut", "pub", "ref", "static", "unsafe", "where", "while",
    ],
    .sql: [
      "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "commit", "constraint",
      "create", "cross", "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists",
      "foreign", "from", "full", "group", "having", "in", "index", "inner", "insert", "into", "is", "join",
      "left", "like", "limit", "not", "offset", "on", "or", "order", "outer", "primary", "references", "right",
      "rollback", "select", "set", "table", "then", "truncate", "union", "unique", "update", "values", "view",
      "when", "where", "with",
    ],
    .swift: [
      "as", "associatedtype", "async", "await", "case", "catch", "convenience", "default", "defer", "didSet",
      "do", "dynamic", "else", "fallthrough", "fileprivate", "final", "for", "get", "guard", "if", "in",
      "indirect", "infix", "internal", "is", "isolated", "lazy", "let", "mutating", "nonisolated", "nonmutating",
      "open", "optional", "override", "postfix", "precedencegroup", "prefix", "private", "public", "repeat",
      "required", "set", "some", "static", "switch", "try", "unowned", "var", "weak", "where", "while", "willSet",
    ],
    .tsx: [
      "abstract", "as", "async", "await", "case", "catch", "const", "declare", "default", "delete", "else",
      "extends", "finally", "for", "if", "in", "infer", "instanceof", "keyof", "let", "namespace", "new", "of",
      "readonly", "satisfies", "static", "switch", "try", "typeof", "var", "while",
    ],
    .typescript: [
      "abstract", "as", "async", "await", "case", "catch", "const", "declare", "default", "delete", "else",
      "extends", "finally", "for", "if", "in", "infer", "instanceof", "keyof", "let", "namespace", "new", "of",
      "readonly", "satisfies", "static", "switch", "try", "typeof", "var", "while",
    ],
  ]
}

struct NativeLexeme: Equatable, Sendable {
  let content: String
  let capture: String?
}

struct NativeLexedLine: Equatable, Sendable {
  let source: String
  let lexemes: [NativeLexeme]
  let endState: NativeLexerState
}

struct NativeLexedDocument: Equatable, Sendable {
  let language: SyntaxLanguage
  let source: String
  let lines: [NativeLexedLine]
}

enum NativeLexerState: Equatable, Sendable {
  case normal
  case blockComment(end: String)
  case multilineString(end: String)
  case htmlTag
}

enum NativeSyntaxLexer {
  static func lex(
    _ source: String,
    as language: SyntaxLanguage,
    reusing previous: NativeLexedDocument? = nil
  ) -> NativeLexedDocument {
    if let previous, previous.language == language, previous.source == source { return previous }

    let sourceLines = source.components(separatedBy: "\n")
    var result: [NativeLexedLine] = []
    var state = NativeLexerState.normal

    if let previous, previous.language == language {
      let reusableCount = zip(sourceLines, previous.lines).prefix {
        $0.0 == $0.1.source
      }.count
      if reusableCount > 0 {
        result.append(contentsOf: previous.lines.prefix(reusableCount))
        state = result.last?.endState ?? .normal
      }
    }

    for line in sourceLines.dropFirst(result.count) {
      let lexed: NativeLexedLine
      switch language {
      case .diff:
        lexed = lexDiffLine(line)
      case .html:
        lexed = lexHTMLLine(line, state: state)
      case .markdown:
        lexed = lexMarkdownLine(line)
      default:
        lexed = lexProgrammingLine(line, language: language, state: state)
      }
      result.append(lexed)
      state = lexed.endState
    }

    return NativeLexedDocument(language: language, source: source, lines: result)
  }
}

private extension NativeSyntaxLexer {
  private static func lexProgrammingLine(
    _ source: String, language: SyntaxLanguage, state initialState: NativeLexerState
  ) -> NativeLexedLine {
    let bytes = Array(source.utf8)
    var builder = LineBuilder(bytes: bytes)
    var index = 0
    var state = initialState
    var expectedDeclaration: String?

    if case let .blockComment(end) = state {
      if let endIndex = find(Array(end.utf8), in: bytes, from: 0) {
        builder.append(0, endIndex + end.utf8.count, "comment")
        index = endIndex + end.utf8.count
        state = .normal
      } else {
        builder.append(0, bytes.count, "comment")
        return builder.finish(source: source, state: state)
      }
    } else if case let .multilineString(end) = state {
      if let endIndex = find(Array(end.utf8), in: bytes, from: 0) {
        builder.appendString(0, endIndex + end.utf8.count)
        index = endIndex + end.utf8.count
        state = .normal
      } else {
        builder.appendString(0, bytes.count)
        return builder.finish(source: source, state: state)
      }
    }

    let lineComments = language.lineComments.map { Array($0.utf8) }
    let blockStart = language.blockComment.map { Array($0.start.utf8) }
    let blockEnd = language.blockComment.map { Array($0.end.utf8) }
    let multiline = language.multilineStrings.map { Array($0.utf8) }

    while index < bytes.count {
      if isWhitespace(bytes[index]) {
        let end = consume(while: isWhitespace, bytes: bytes, from: index)
        builder.append(index, end, nil)
        index = end
        continue
      }

      if let marker = lineComments.first(where: { starts(with: $0, bytes: bytes, at: index) }) {
        _ = marker
        builder.append(index, bytes.count, "comment")
        index = bytes.count
        continue
      }

      if let blockStart, let blockEnd, starts(with: blockStart, bytes: bytes, at: index) {
        if let endIndex = find(blockEnd, in: bytes, from: index + blockStart.count) {
          let end = endIndex + blockEnd.count
          builder.append(index, end, "comment")
          index = end
        } else {
          builder.append(index, bytes.count, "comment")
          state = .blockComment(end: String(decoding: blockEnd, as: UTF8.self))
          index = bytes.count
        }
        continue
      }

      if let delimiter = multiline.first(where: { starts(with: $0, bytes: bytes, at: index) }) {
        let searchStart = index + delimiter.count
        if let endIndex = find(delimiter, in: bytes, from: searchStart) {
          let end = endIndex + delimiter.count
          builder.appendString(index, end)
          index = end
        } else {
          builder.appendString(index, bytes.count)
          state = .multilineString(end: String(decoding: delimiter, as: UTF8.self))
          index = bytes.count
        }
        continue
      }

      if language.quotes.contains(bytes[index]) {
        let end = quotedEnd(in: bytes, from: index, quote: bytes[index])
        if language.isPropertyLanguage, nextNonWhitespace(in: bytes, after: end) == 58 {
          builder.append(index, end, "property")
        } else {
          builder.appendString(index, end)
        }
        index = end
        continue
      }

      if isNumberStart(bytes, at: index) {
        let end = numberEnd(in: bytes, from: index)
        builder.append(index, end, "number")
        index = end
        continue
      }

      if bytes[index] == 64, index + 1 < bytes.count, isIdentifierStart(bytes[index + 1]) {
        let end = identifierEnd(in: bytes, from: index + 1)
        builder.append(index, end, "attribute")
        index = end
        continue
      }

      if bytes[index] == 36, index + 1 < bytes.count,
        isIdentifierStart(bytes[index + 1]) || bytes[index + 1] == 123
      {
        let end: Int
        if bytes[index + 1] == 123, let close = bytes[(index + 2)...].firstIndex(of: 125) {
          end = close + 1
        } else {
          end = identifierEnd(in: bytes, from: index + 1)
        }
        builder.append(index, end, "variable")
        index = end
        continue
      }

      if isIdentifierStart(bytes[index]) {
        let end = identifierEnd(in: bytes, from: index)
        let word = String(decoding: bytes[index..<end], as: UTF8.self)
        var capture = language.capture(for: word)
        if capture == nil, let expectedDeclaration {
          capture = expectedDeclaration
        } else if capture == nil {
          let previous = previousNonWhitespace(in: bytes, before: index)
          let next = nextNonWhitespace(in: bytes, after: end)
          if previous == 46 {
            capture = "property"
          } else if next == 40 {
            capture = "function.call"
          } else if language.isPropertyLanguage, next == 58 {
            capture = "property"
          } else if bytes[index] >= 65, bytes[index] <= 90 {
            capture = "type"
          } else {
            capture = "variable"
          }
        }
        builder.append(index, end, capture)
        expectedDeclaration = language.declarationCapture(after: word)
        index = end
        continue
      }

      if isOperator(bytes[index]) {
        let end = consume(while: isOperator, bytes: bytes, from: index)
        builder.append(index, end, "operator")
        index = end
        continue
      }

      let capture = isBracket(bytes[index]) ? "punctuation.bracket" : "punctuation.delimiter"
      builder.append(index, index + 1, capture)
      index += 1
    }

    return builder.finish(source: source, state: state)
  }

  private static func lexDiffLine(_ source: String) -> NativeLexedLine {
    let capture: String?
    if source.hasPrefix("@@") {
      capture = "markup.changed"
    } else if source.hasPrefix("+++") || source.hasPrefix("---")
      || source.hasPrefix("diff ") || source.hasPrefix("index ")
    {
      capture = "meta"
    } else if source.hasPrefix("+") {
      capture = "markup.inserted"
    } else if source.hasPrefix("-") {
      capture = "markup.deleted"
    } else {
      capture = nil
    }
    return NativeLexedLine(
      source: source,
      lexemes: source.isEmpty ? [] : [NativeLexeme(content: source, capture: capture)],
      endState: .normal
    )
  }

  private static func lexMarkdownLine(_ source: String) -> NativeLexedLine {
    let bytes = Array(source.utf8)
    var builder = LineBuilder(bytes: bytes)
    var index = 0

    if let first = bytes.first, first == 35 {
      let markerEnd = consume(while: { $0 == 35 }, bytes: bytes, from: 0)
      if markerEnd < bytes.count, isWhitespace(bytes[markerEnd]) {
        builder.append(0, markerEnd, "punctuation.delimiter")
        builder.append(markerEnd, bytes.count, "markup.heading")
        return builder.finish(source: source, state: .normal)
      }
    }

    while index < bytes.count {
      if starts(with: Array("https://".utf8), bytes: bytes, at: index)
        || starts(with: Array("http://".utf8), bytes: bytes, at: index)
      {
        var end = index
        while end < bytes.count, !isWhitespace(bytes[end]), bytes[end] != 41, bytes[end] != 93 {
          end += 1
        }
        builder.append(index, end, "markup.link")
        index = end
      } else if bytes[index] == 96 {
        let delimiterEnd = consume(while: { $0 == 96 }, bytes: bytes, from: index)
        let delimiter = Array(bytes[index..<delimiterEnd])
        if let endIndex = find(delimiter, in: bytes, from: delimiterEnd) {
          let end = endIndex + delimiter.count
          builder.append(index, end, "string")
          index = end
        } else {
          builder.append(index, bytes.count, "string")
          index = bytes.count
        }
      } else if bytes[index] == 42 || bytes[index] == 95 {
        let end = consume(while: { $0 == bytes[index] }, bytes: bytes, from: index)
        builder.append(index, end, end - index > 1 ? "markup.bold" : "markup.italic")
        index = end
      } else if bytes[index] == 62 || bytes[index] == 35 || bytes[index] == 45
        || bytes[index] == 91 || bytes[index] == 93 || bytes[index] == 40
        || bytes[index] == 41
      {
        builder.append(index, index + 1, "punctuation.delimiter")
        index += 1
      } else {
        let end = consume(
          while: { ![96, 42, 95, 62, 35, 45, 91, 93, 40, 41].contains($0) },
          bytes: bytes,
          from: index
        )
        builder.append(index, max(end, index + 1), nil)
        index = max(end, index + 1)
      }
    }
    return builder.finish(source: source, state: .normal)
  }

  private static func lexHTMLLine(
    _ source: String, state initialState: NativeLexerState
  ) -> NativeLexedLine {
    let bytes = Array(source.utf8)
    var builder = LineBuilder(bytes: bytes)
    var index = 0
    var insideTag = initialState == .htmlTag
    var state = initialState

    if case let .blockComment(end) = state {
      let marker = Array(end.utf8)
      if let endIndex = find(marker, in: bytes, from: 0) {
        builder.append(0, endIndex + marker.count, "comment")
        index = endIndex + marker.count
        state = .normal
      } else {
        builder.append(0, bytes.count, "comment")
        return builder.finish(source: source, state: state)
      }
    }

    var expectsTagName = false
    while index < bytes.count {
      if !insideTag {
        let commentStart = Array("<!--".utf8)
        if starts(with: commentStart, bytes: bytes, at: index) {
          let commentEnd = Array("-->".utf8)
          if let endIndex = find(commentEnd, in: bytes, from: index + commentStart.count) {
            let end = endIndex + commentEnd.count
            builder.append(index, end, "comment")
            index = end
          } else {
            builder.append(index, bytes.count, "comment")
            state = .blockComment(end: "-->")
            index = bytes.count
          }
        } else if bytes[index] == 60 {
          let end = index + ((index + 1 < bytes.count && bytes[index + 1] == 47) ? 2 : 1)
          builder.append(index, end, "punctuation.bracket")
          index = end
          insideTag = true
          expectsTagName = true
        } else {
          let nextTag = bytes[index...].firstIndex(of: 60) ?? bytes.count
          builder.append(index, nextTag, nil)
          index = nextTag
        }
        continue
      }

      if isWhitespace(bytes[index]) {
        let end = consume(while: isWhitespace, bytes: bytes, from: index)
        builder.append(index, end, nil)
        index = end
      } else if bytes[index] == 62 {
        builder.append(index, index + 1, "punctuation.bracket")
        index += 1
        insideTag = false
        expectsTagName = false
        state = .normal
      } else if bytes[index] == 47, index + 1 < bytes.count, bytes[index + 1] == 62 {
        builder.append(index, index + 2, "punctuation.bracket")
        index += 2
        insideTag = false
        expectsTagName = false
        state = .normal
      } else if bytes[index] == 34 || bytes[index] == 39 {
        let end = quotedEnd(in: bytes, from: index, quote: bytes[index])
        builder.appendString(index, end)
        index = end
      } else if bytes[index] == 61 {
        builder.append(index, index + 1, "operator")
        index += 1
      } else if isIdentifierStart(bytes[index]) || bytes[index] == 33 {
        let end = consume(
          while: { isIdentifierContinue($0) || $0 == 45 || $0 == 58 || $0 == 33 },
          bytes: bytes,
          from: index
        )
        builder.append(index, end, expectsTagName ? "tag" : "attribute")
        expectsTagName = false
        index = end
      } else {
        builder.append(index, index + 1, "punctuation.delimiter")
        index += 1
      }
    }

    if insideTag, state == .normal { state = .htmlTag }
    return builder.finish(source: source, state: state)
  }

  private struct LineBuilder {
    let bytes: [UInt8]
    var lexemes: [NativeLexeme] = []

    mutating func append(_ start: Int, _ end: Int, _ capture: String?) {
      guard end > start else { return }
      let content = String(decoding: bytes[start..<end], as: UTF8.self)
      if let last = lexemes.last, last.capture == capture {
        lexemes[lexemes.count - 1] = NativeLexeme(
          content: last.content + content,
          capture: capture
        )
      } else {
        lexemes.append(NativeLexeme(content: content, capture: capture))
      }
    }

    mutating func appendString(_ start: Int, _ end: Int) {
      var cursor = start
      var plainStart = start
      while cursor < end {
        if bytes[cursor] == 92, cursor + 1 < end {
          append(plainStart, cursor, "string")
          append(cursor, min(cursor + 2, end), "string.escape")
          cursor += 2
          plainStart = cursor
        } else {
          cursor += 1
        }
      }
      append(plainStart, end, "string")
    }

    func finish(source: String, state: NativeLexerState) -> NativeLexedLine {
      NativeLexedLine(source: source, lexemes: lexemes, endState: state)
    }
  }

  private static func starts(with marker: [UInt8], bytes: [UInt8], at index: Int) -> Bool {
    guard !marker.isEmpty, index + marker.count <= bytes.count else { return false }
    return bytes[index..<(index + marker.count)].elementsEqual(marker)
  }

  private static func find(_ marker: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
    guard !marker.isEmpty, start <= bytes.count - marker.count else { return nil }
    for index in start...(bytes.count - marker.count) where starts(with: marker, bytes: bytes, at: index) {
      return index
    }
    return nil
  }

  private static func consume(
    while predicate: (UInt8) -> Bool, bytes: [UInt8], from start: Int
  ) -> Int {
    var index = start
    while index < bytes.count, predicate(bytes[index]) { index += 1 }
    return index
  }

  private static func quotedEnd(in bytes: [UInt8], from start: Int, quote: UInt8) -> Int {
    var index = start + 1
    while index < bytes.count {
      if bytes[index] == 92 {
        index = min(index + 2, bytes.count)
      } else if bytes[index] == quote {
        return index + 1
      } else {
        index += 1
      }
    }
    return bytes.count
  }

  private static func identifierEnd(in bytes: [UInt8], from start: Int) -> Int {
    consume(while: isIdentifierContinue, bytes: bytes, from: start)
  }

  private static func numberEnd(in bytes: [UInt8], from start: Int) -> Int {
    consume(
      while: { byte in
        isASCIILetter(byte) || isDigit(byte) || byte == 46 || byte == 95
      },
      bytes: bytes,
      from: start
    )
  }

  private static func previousNonWhitespace(in bytes: [UInt8], before index: Int) -> UInt8? {
    guard index > 0 else { return nil }
    var cursor = index - 1
    while isWhitespace(bytes[cursor]) {
      guard cursor > 0 else { return nil }
      cursor -= 1
    }
    return bytes[cursor]
  }

  private static func nextNonWhitespace(in bytes: [UInt8], after index: Int) -> UInt8? {
    var cursor = index
    while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
    return cursor < bytes.count ? bytes[cursor] : nil
  }

  private static func isNumberStart(_ bytes: [UInt8], at index: Int) -> Bool {
    isDigit(bytes[index])
      || (bytes[index] == 46 && index + 1 < bytes.count && isDigit(bytes[index + 1]))
  }

  private static func isIdentifierStart(_ byte: UInt8) -> Bool {
    isASCIILetter(byte) || byte == 95 || byte >= 128
  }

  private static func isIdentifierContinue(_ byte: UInt8) -> Bool {
    isIdentifierStart(byte) || isDigit(byte)
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
  }

  private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 9 || byte == 10 || byte == 13 || byte == 32
  }
  private static func isOperator(_ byte: UInt8) -> Bool {
    [33, 37, 38, 42, 43, 45, 46, 47, 58, 60, 61, 62, 63, 94, 124, 126].contains(byte)
  }
  private static func isBracket(_ byte: UInt8) -> Bool {
    [40, 41, 91, 93, 123, 125].contains(byte)
  }
}
