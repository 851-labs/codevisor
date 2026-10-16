import CodeHighlighter
import CodevisorTheming
import StreamMarkdown
import SwiftUI

public func makeMarkdownTheme(highlight: (key: String, json: String)?) -> MarkdownTheme {
  var markdown = MarkdownTheme.default
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
