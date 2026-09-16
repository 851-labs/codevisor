import Foundation

/// Resolves Tree-sitter captures against the app’s VS Code/TextMate themes.
struct NativeSyntaxTheme: Sendable {
  private struct Document: Decodable {
    var tokenColors: [Rule]?
    var settings: [Rule]?
  }

  private struct Rule: Decodable {
    var scope: ScopeList?
    var settings: Settings?
  }

  private struct Settings: Decodable {
    var foreground: String?
    var fontStyle: String?
  }

  private enum ScopeList: Decodable {
    case one(String)
    case many([String])

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(String.self) {
        self = .one(value)
      } else {
        self = .many(try container.decode([String].self))
      }
    }

    var values: [String] {
      switch self {
      case let .one(value): [value]
      case let .many(values): values
      }
    }
  }

  private struct CompiledRule: Sendable {
    let selectors: [Selector]
    let foreground: String?
    let fontStyle: String?
    let order: Int
  }

  private struct Selector: Sendable {
    let required: [String]
    let excluded: [String]

    init?(_ source: String) {
      var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("L:") || value.hasPrefix("R:") {
        value.removeFirst(2)
        value = value.trimmingCharacters(in: .whitespaces)
      }
      guard !value.isEmpty else { return nil }

      let pieces = value.components(separatedBy: " - ")
      required = pieces[0].split(whereSeparator: \.isWhitespace).map(String.init)
      excluded = pieces.dropFirst().flatMap {
        $0.split(whereSeparator: \.isWhitespace).map(String.init)
      }
      guard !required.isEmpty else { return nil }
    }

    func score(in stack: [String]) -> Int? {
      guard excluded.allSatisfy({ term in !stack.contains(where: { matches(term, $0) }) })
      else { return nil }

      var stackIndex = stack.count - 1
      var score = 0
      for term in required.reversed() {
        var matchIndex: Int?
        while stackIndex >= 0 {
          if matches(term, stack[stackIndex]) {
            matchIndex = stackIndex
            break
          }
          stackIndex -= 1
        }
        guard let matchIndex else { return nil }
        let componentCount = term.split(separator: ".").count
        score += componentCount * 100 + term.count
        // A selector naming the leaf scope is more specific than one
        // that only matches a parent scope.
        if matchIndex == stack.count - 1 { score += 10_000 }
        stackIndex = matchIndex - 1
      }
      score += required.count * 1_000
      return score
    }

    private func matches(_ selector: String, _ scope: String) -> Bool {
      selector == "*" || scope == selector || scope.hasPrefix(selector + ".")
    }
  }

  private let rules: [CompiledRule]

  init(json: String) throws {
    let document = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
    let sourceRules = document.tokenColors ?? document.settings ?? []
    rules = sourceRules.enumerated().compactMap { index, rule in
      guard let settings = rule.settings, settings.foreground != nil || settings.fontStyle != nil else { return nil }
      let rawScopes = rule.scope?.values ?? []
      let selectors =
        rawScopes
        .flatMap { $0.split(separator: ",").map(String.init) }
        .compactMap(Selector.init)
      guard !selectors.isEmpty else { return nil }
      return CompiledRule(
        selectors: selectors, foreground: settings.foreground, fontStyle: settings.fontStyle, order: index)
    }
  }

  func style(for capture: String, language: SyntaxLanguage) -> CodeHighlightDocument.Style {
    let root = language.textMateRootScope
    var color: (score: Int, order: Int, value: String)?
    var font: (score: Int, order: Int, value: String)?
    var category = Self.normalized(capture)
    var scopes: [String] = []
    while true {
      let mapped = Self.textMateScopes(for: category)
      scopes += mapped
      if mapped != [category] { break }
      guard let dot = category.lastIndex(of: ".") else { break }
      category = String(category[..<dot])
    }
    for leaf in scopes {
      for rule in rules {
        for selector in rule.selectors {
          guard let score = selector.score(in: [root, leaf]) else { continue }
          if let value = rule.foreground,
            color == nil || score > color!.score || (score == color!.score && rule.order >= color!.order)
          {
            color = (score, rule.order, value)
          }
          if let value = rule.fontStyle,
            font == nil || score > font!.score || (score == font!.score && rule.order >= font!.order)
          {
            font = (score, rule.order, value)
          }
        }
      }
    }
    let traits = font?.value.split(separator: " ") ?? []
    return .init(foreground: color?.value, bold: traits.contains("bold"), italic: traits.contains("italic"))
  }

  private static func normalized(_ capture: String) -> String {
    switch capture {
    case "diff.plus": "markup.inserted"
    case "diff.minus": "markup.deleted"
    case "diff.delta": "markup.changed"
    case "text.title", "markup.heading": "markup.heading"
    case "text.literal", "markup.raw": "string"
    case "text.uri", "text.reference", "markup.link.url": "markup.link"
    case "text.strong", "markup.strong": "markup.bold"
    case "text.emphasis", "markup.emphasis": "markup.italic"
    case "constant.builtin": "constant"
    case "constructor": "type"
    case "variable.member": "property"
    case "string.special.key": "property"
    case "escape": "string.escape"
    case "attribute": "attribute"
    default: capture
    }
  }

  private static func textMateScopes(for capture: String) -> [String] {
    switch capture {
    case "comment":
      ["comment.line", "comment"]
    case "comment.documentation":
      ["comment.block.documentation", "comment"]
    case "keyword.function":
      ["storage.type.function", "keyword.control", "keyword"]
    case "keyword.type":
      ["storage.type", "storage", "keyword"]
    case "keyword.return":
      ["keyword.control.flow", "keyword.control", "keyword"]
    case "keyword.import":
      ["keyword.control.import", "keyword.control", "keyword"]
    case "keyword":
      ["keyword.control", "keyword"]
    case "operator":
      ["keyword.operator", "operator"]
    case "number":
      ["constant.numeric", "constant"]
    case "boolean":
      ["constant.language.boolean", "constant.language", "constant"]
    case "constant":
      ["constant.language", "constant"]
    case "string":
      ["string.quoted", "string"]
    case "string.special":
      ["string.interpolated", "string"]
    case "string.escape":
      ["constant.character.escape", "constant"]
    case "string.regex":
      ["string.regexp", "string"]
    case "function":
      ["entity.name.function", "support.function", "function"]
    case "function.call":
      ["support.function", "entity.name.function", "function"]
    case "function.builtin":
      ["support.function.builtin", "support.function", "function"]
    case "type":
      ["entity.name.type", "support.type", "type"]
    case "type.builtin":
      ["support.type", "storage.type", "type"]
    case "variable":
      ["variable.other", "variable"]
    case "variable.builtin":
      ["variable.language", "variable"]
    case "variable.parameter":
      ["variable.parameter", "variable"]
    case "property":
      ["variable.other.property", "support.type.property-name", "property"]
    case "attribute":
      ["entity.other.attribute-name", "support.type.property-name", "attribute"]
    case "tag":
      ["entity.name.tag", "tag"]
    case "label":
      ["entity.name.label", "label"]
    case "namespace":
      ["entity.name.namespace", "namespace"]
    case "punctuation.bracket":
      ["punctuation.definition", "punctuation"]
    case "punctuation.delimiter":
      ["punctuation.separator", "punctuation"]
    case "markup.heading":
      ["markup.heading", "entity.name.section"]
    case "markup.bold":
      ["markup.bold"]
    case "markup.italic":
      ["markup.italic"]
    case "markup.link":
      ["markup.underline.link", "string.other.link"]
    case "markup.inserted":
      ["markup.inserted.diff", "markup.inserted"]
    case "markup.deleted":
      ["markup.deleted.diff", "markup.deleted"]
    case "markup.changed":
      ["markup.changed.diff", "markup.changed"]
    case "meta":
      ["meta.diff.header", "meta"]
    default:
      [capture]
    }
  }
}
