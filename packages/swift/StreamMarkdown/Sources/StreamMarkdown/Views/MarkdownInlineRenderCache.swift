#if canImport(AppKit) || canImport(UIKit)
  import Foundation
  import MarkdownCore
  import Synchronization

  final class MarkdownInlineRenderCache: Sendable {
    struct Key: Hashable, @unchecked Sendable {
      let markdown: MarkdownText
      let font: MarkdownNativeFont
      let foreground: MarkdownNativeColor
      let chipColor: MarkdownNativeColor
      let chipCornerRadius: CGFloat
      let themeFingerprint: Int
    }

    private struct Entry: @unchecked Sendable {
      let text: NSAttributedString
    }

    static let shared = MarkdownInlineRenderCache()
    private static let capacity = 1024
    private let entries = Mutex<[Key: Entry]>([:])

    func text(for key: Key, render: () -> NSAttributedString) -> NSAttributedString {
      if let hit = entries.withLock({ $0[key] }) { return hit.text }

      let text = render()
      entries.withLock { entries in
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(text: text)
      }
      return text
    }
  }
#endif
