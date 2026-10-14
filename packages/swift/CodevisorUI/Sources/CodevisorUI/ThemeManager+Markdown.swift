import CodeHighlighter
import CodevisorCore
import CodevisorTheming
import StreamMarkdown
import SwiftUI

@MainActor
private var highlightThemeCache: [String: (key: String, json: String)] = [:]

extension ThemeManager {
  public func highlightTheme(for scheme: ThemeDescriptor.SchemeType) -> (key: String, json: String)? {
    let id = themeId(for: scheme)
    let effectiveId =
      ThemeCatalog.isSystemTheme(id: id)
      ? (scheme == .dark ? "shiki:github-dark" : "shiki:github-light")
      : id
    if let cached = highlightThemeCache[effectiveId] { return cached }
    guard
      let data = try? catalog.loadThemeData(id: effectiveId),
      let json = String(data: data, encoding: .utf8)
    else { return nil }
    let resolved = (effectiveId, json)
    highlightThemeCache[effectiveId] = resolved
    return resolved
  }
}

public func makeMarkdownTheme(theme: Theme, highlight: (key: String, json: String)?) -> MarkdownTheme {
  var markdown = MarkdownTheme.default
  markdown.textForeground = theme.textPrimary
  markdown.secondaryTextForeground = theme.textSecondary
  markdown.codeForeground = theme.textPrimary
  if let palette = theme.palette {
    markdown.codeBackground = Color(rgba: palette.codeBackground)
    markdown.inlineCodeBackground = Color(rgba: palette.cardHoverBackground)
    markdown.quoteBarColor = theme.border
    markdown.tableBorderColor = theme.separator
  }
  if let highlight {
    markdown.codeThemeKey = highlight.key
    markdown.codeHighlighter = { request in
      guard
        let tokens = await CodeHighlighter.shared.highlight(
          code: request.code,
          language: request.language,
          themeKey: highlight.key,
          themeJSON: highlight.json,
          sessionID: request.id,
          isComplete: request.isComplete
        )
      else { return nil }
      return attributedCode(tokens)
    }
  }
  return markdown
}

private func attributedCode(_ lines: [[CodeHighlighter.Token]]) -> AttributedString {
  var result = AttributedString()
  for (index, line) in lines.enumerated() {
    if index > 0 { result += AttributedString("\n") }
    result += attributedLine(line)
  }
  return result
}

public func attributedLine(_ line: [CodeHighlighter.Token]) -> AttributedString {
  var result = AttributedString()
  for token in line {
    var piece = AttributedString(token.content)
    if let color = token.color, let rgba = RGBA(css: color) {
      piece.foregroundColor = Color(rgba: rgba)
    }
    var intent = piece.inlinePresentationIntent ?? []
    if token.bold { intent.insert(.stronglyEmphasized) }
    if token.italic { intent.insert(.emphasized) }
    if !intent.isEmpty { piece.inlinePresentationIntent = intent }
    result += piece
  }
  return result
}
