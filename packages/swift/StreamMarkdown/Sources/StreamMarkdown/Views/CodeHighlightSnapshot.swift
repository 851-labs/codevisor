import Foundation

/// A highlight result belongs to exact source and theme. An append can keep
/// its colored prefix, but must expose the new suffix immediately while the
/// next highlight is pending. Replacements never reuse stale characters.
struct CodeHighlightSnapshot {
  let source: String
  let language: String?
  let themeKey: String
  let text: AttributedString

  func renderedText(source: String, language: String?, themeKey: String) -> AttributedString? {
    guard self.language == language, self.themeKey == themeKey,
      source.hasPrefix(self.source)
    else { return nil }
    if source == self.source { return text }
    let suffix = source.utf8.dropFirst(self.source.utf8.count)
    return text + AttributedString(String(decoding: suffix, as: UTF8.self))
  }
}
