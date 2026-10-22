#if canImport(AppKit)
  import AppKit

  @MainActor
  enum SettledMarkdownText {
    static func attributedText(
      for blocks: [MarkdownBlock],
      theme: MarkdownTheme
    ) -> NSAttributedString {
      let key = MarkdownTextRunCache.Key(
        blocks: blocks,
        themeFingerprint: theme.renderFingerprint,
        foregroundColor: .init(theme.textForeground)
      )
      if let cached = MarkdownTextRunCache.shared.value(for: key) { return cached }
      let value = MarkdownTextRunRenderer.attributedString(
        for: blocks,
        theme: theme,
        foregroundColor: theme.textForeground
      )
      MarkdownTextRunCache.shared.store(value, for: key)
      return value
    }
  }
#endif
