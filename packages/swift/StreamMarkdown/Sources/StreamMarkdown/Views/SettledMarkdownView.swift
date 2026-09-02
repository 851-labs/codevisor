#if canImport(AppKit)
  import AppKit
  import SwiftUI

  /// Flat native renderer for immutable Markdown.
  ///
  /// A text-compatible run becomes one TextKit 2 view. Code, tables, and
  /// separators use dedicated AppKit views. No SwiftUI hosting controller is
  /// involved, which makes the complete object graph safe to retain in the
  /// transcript's bounded prepared-surface cache.
  @MainActor
  public final class SettledMarkdownView: NSView {
    private struct ContentKey: Equatable {
      let blocks: [MarkdownBlock]
      let themeFingerprint: Int
      let streamID: String
    }

    private var contentKey: ContentKey?
    private var contentViews: [NativeMarkdownContentView] = []
    private var blockSpacing: CGFloat = 0
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public func setContent(
      blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      streamID: String,
      linkAction: MarkdownLinkAction?
    ) {
      precondition(!blocks.isEmpty, "Settled Markdown requires at least one block")
      let key = ContentKey(
        blocks: blocks,
        themeFingerprint: theme.renderFingerprint,
        streamID: streamID
      )
      guard key != contentKey else {
        contentViews.forEach { $0.linkAction = linkAction }
        return
      }

      contentViews.forEach { $0.removeFromSuperview() }
      contentViews = makeContentViews(
        blocks: blocks,
        theme: theme,
        streamID: streamID,
        linkAction: linkAction
      )
      contentViews.forEach(addSubview)
      contentKey = key
      blockSpacing = theme.blockSpacing
      measuredWidth = -1
      needsLayout = true
    }

    public func contentHeight(forWidth proposedWidth: CGFloat) -> CGFloat {
      let width = max(1, proposedWidth)
      if abs(measuredWidth - width) <= 0.25 { return measuredHeight }
      measuredWidth = width
      measuredHeight = max(
        1,
        contentViews.enumerated().reduce(0) { height, entry in
          let spacing = entry.offset == 0 ? 0 : blockSpacing
          return height + spacing + entry.element.contentHeight(forWidth: width)
        }
      )
      return measuredHeight
    }

    public override func layout() {
      super.layout()
      if contentViews.count == 1, let view = contentViews.first {
        view.frame = bounds
        return
      }
      var y: CGFloat = 0
      for (index, view) in contentViews.enumerated() {
        if index > 0 { y += blockSpacing }
        let height = view.contentHeight(forWidth: bounds.width)
        view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        y += height
      }
    }

    private func makeContentViews(
      blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      streamID: String,
      linkAction: MarkdownLinkAction?
    ) -> [NativeMarkdownContentView] {
      if MarkdownTextRunRenderer.canRenderAsTextRun(blocks) {
        return [
          NativeMarkdownTextContentView(
            blocks: blocks,
            theme: theme,
            linkAction: linkAction
          )
        ]
      }

      return blocks.enumerated().map { index, block in
        let blockID = "\(streamID).\(index)"
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList, .blockQuote:
          return NativeMarkdownTextContentView(
            blocks: [block],
            theme: theme,
            linkAction: linkAction
          )
        case let .list(list):
          precondition(
            MarkdownTextRunRenderer.canRenderFlattenedList(list),
            "Complex lists must be structurally projected before native rendering"
          )
          return NativeMarkdownTextContentView(
            blocks: [block],
            theme: theme,
            linkAction: linkAction
          )
        case let .codeBlock(language, code, _):
          return NativeMarkdownCodeBlockView(
            id: blockID,
            language: language,
            code: code,
            theme: theme
          )
        case let .table(headers, alignments, rows):
          return NativeMarkdownTableBlockView(
            headers: headers,
            alignments: alignments,
            rows: rows,
            theme: theme,
            linkAction: linkAction
          )
        case .thematicBreak:
          return NativeMarkdownSeparatorView(color: NSColor(theme.tableBorderColor))
        }
      }
    }
  }

  @MainActor
  class NativeMarkdownContentView: NSView {
    var linkAction: MarkdownLinkAction? {
      didSet { linkActionDidChange() }
    }
    func linkActionDidChange() {}
    func contentHeight(forWidth _: CGFloat) -> CGFloat { 1 }
  }

  @MainActor
  private final class NativeMarkdownTextContentView: NativeMarkdownContentView {
    private let textView = MarkdownTextKit2View()

    init(
      blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      linkAction: MarkdownLinkAction?
    ) {
      super.init(frame: .zero)
      self.linkAction = linkAction
      textView.linkAction = linkAction
      textView.setContent(Self.attributedText(for: blocks, theme: theme))
      addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func linkActionDidChange() {
      textView.linkAction = linkAction
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
      textView.contentHeight(forWidth: width)
    }

    override func layout() {
      super.layout()
      textView.frame = bounds
    }

    private static func attributedText(
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

  @MainActor
  private final class NativeMarkdownSeparatorView: NativeMarkdownContentView {
    init(color: NSColor) {
      super.init(frame: .zero)
      wantsLayer = true
      layer?.backgroundColor = color.cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func contentHeight(forWidth _: CGFloat) -> CGFloat { 1 }
  }

  extension MarkdownTextRunRenderer {
    static func canRenderAsTextRun(_ blocks: [MarkdownBlock]) -> Bool {
      blocks.allSatisfy { block in
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
          true
        case let .list(list): canRenderFlattenedList(list)
        case let .blockQuote(blocks): canRenderFlattenedText(blocks)
        case .codeBlock, .table, .thematicBreak:
          false
        }
      }
    }
  }
#endif
