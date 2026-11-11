#if canImport(AppKit) || canImport(UIKit)
  import MarkdownCore
  import SwiftUI

  @MainActor
  final class MarkdownTextRunMemo {
    private struct Style: Equatable {
      let fingerprint: Int
      let foregroundColor: Color
    }

    private struct Prefix {
      let blocks: [MarkdownBlock]
      let assembly: MarkdownTextRunAssembly
    }

    private var blocks: [MarkdownBlock]?
    private var style: Style?
    private var cached: NSAttributedString?
    private var prefix: Prefix?

    func rendered(
      for blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      foregroundColor: Color
    ) -> NSAttributedString {
      let style = Style(
        fingerprint: theme.renderFingerprint ^ MarkdownTextRunRenderer.bodyFont.pointSize.hashValue,
        foregroundColor: foregroundColor)
      if let cached, style == self.style, blocks == self.blocks { return cached }

      if style != self.style { prefix = nil }
      let rendered =
        extended(to: blocks)
        ?? fullyRendered(blocks, theme: theme, foregroundColor: foregroundColor, fingerprint: style.fingerprint)
      self.blocks = blocks
      self.style = style
      cached = rendered
      return rendered
    }

    private func extended(to blocks: [MarkdownBlock]) -> NSAttributedString? {
      guard let last = blocks.last, let prefix else { return nil }

      let head = blocks.dropLast()
      if head.elementsEqual(prefix.blocks) {
        return prefix.assembly.appending(last).snapshot
      }
      guard let completed = head.last, head.dropLast().elementsEqual(prefix.blocks) else { return nil }

      let grown = Prefix(blocks: Array(head), assembly: prefix.assembly.appending(completed))
      self.prefix = grown
      return grown.assembly.appending(last).snapshot
    }

    private func fullyRendered(
      _ blocks: [MarkdownBlock], theme: MarkdownTheme, foregroundColor: Color, fingerprint: Int
    ) -> NSAttributedString {
      let key = MarkdownTextRunCache.Key(
        blocks: blocks, themeFingerprint: fingerprint, foregroundColor: .init(foregroundColor))
      if let cachedRun = MarkdownTextRunCache.shared.value(for: key) {
        prefix = nil
        return cachedRun
      }

      let head = Array(blocks.dropLast())
      let assembly = MarkdownTextRunAssembly(head, theme: theme, foregroundColor: foregroundColor)
      prefix = Prefix(blocks: head, assembly: assembly)
      let rendered = blocks.last.map { assembly.appending($0).snapshot } ?? assembly.snapshot
      MarkdownTextRunCache.shared.store(rendered, for: key)
      return rendered
    }
  }
#endif
