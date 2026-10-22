#if canImport(AppKit)
  import AppKit
  import SwiftUI

  @MainActor
  public final class SettledMarkdownView: NSView {
    private struct ContentKey: Equatable {
      let blocks: [MarkdownBlock]
      let themeFingerprint: Int
      let streamID: String
      let imageLoaderID: String
    }

    public var onContentHeightChange: (() -> Void)?
    public var tableBleedLimit: CGFloat = .greatestFiniteMagnitude {
      didSet {
        guard tableBleedLimit != oldValue else { return }
        contentViews.forEach { $0.tableBleedLimit = tableBleedLimit }
      }
    }
    private var contentKey: ContentKey?
    private var contentViews: [NativeMarkdownContentView] = []
    private var gaps: [CGFloat] = []
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
      linkAction: MarkdownLinkAction?,
      imageLoader: MarkdownImageLoader = .remote
    ) {
      precondition(!blocks.isEmpty, "Settled Markdown requires at least one block")
      let key = ContentKey(
        blocks: blocks,
        themeFingerprint: theme.renderFingerprint,
        streamID: streamID,
        imageLoaderID: imageLoader.id
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
        linkAction: linkAction,
        imageLoader: imageLoader
      )
      contentViews.forEach { view in
        view.tableBleedLimit = tableBleedLimit
        view.onContentChange = { [weak self] in
          guard let self else { return }
          measuredWidth = -1
          needsLayout = true
          invalidateIntrinsicContentSize()
          onContentHeightChange?()
        }
        addSubview(view)
      }
      contentKey = key
      gaps = Self.gaps(between: blocks, viewCount: contentViews.count, theme: theme)
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
          height + gaps[entry.offset] + entry.element.contentHeight(forWidth: width)
        }
      )
      return measuredHeight
    }

    public static func prefetch(
      blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      streamID: String,
      width: CGFloat,
      scale: CGFloat,
      appearance: NSAppearance.Name
    ) {
      guard !blocks.isEmpty else { return }
      if MarkdownTextRunRenderer.canRenderAsTextRun(blocks) {
        StaticMarkdownTextContentView.prefetch(
          blocks: blocks, theme: theme, streamID: streamID, width: width, scale: scale, appearance: appearance)
        return
      }
      for (index, block) in blocks.enumerated() {
        prefetch(block, id: "\(streamID).\(index)", theme: theme, width: width, scale: scale, appearance: appearance)
      }
    }

    private static func prefetch(
      _ block: MarkdownBlock,
      id: String,
      theme: MarkdownTheme,
      width: CGFloat,
      scale: CGFloat,
      appearance: NSAppearance.Name
    ) {
      switch block {
      case .heading, .paragraph, .bulletList, .orderedList, .blockQuote, .list:
        StaticMarkdownTextContentView.prefetch(
          blocks: [block], theme: theme, streamID: id, width: width, scale: scale, appearance: appearance)
      case let .codeBlock(language, code, _):
        NativeMarkdownCodeBlockView.prefetch(
          id: id, language: language, code: code, theme: theme, scale: scale, appearance: appearance)
      case .table, .thematicBreak:
        break
      }
    }

    public var isContentReady: Bool { contentViews.allSatisfy(\.isContentReady) }

    public static func plainTextSurfaces(
      blocks: [MarkdownBlock],
      theme: MarkdownTheme
    ) -> [String] {
      if MarkdownTextRunRenderer.canRenderAsTextRun(blocks) {
        return [SettledMarkdownText.attributedText(for: blocks, theme: theme).string]
      }
      return blocks.compactMap { block in
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList, .blockQuote, .list:
          return SettledMarkdownText.attributedText(for: [block], theme: theme).string
        case let .codeBlock(_, code, _):
          return code
        case let .table(headers, _, rows):
          return ([headers] + rows)
            .map { $0.map(\.plainText).joined(separator: "\t") }
            .joined(separator: "\n")
        case .thematicBreak:
          return nil
        }
      }
    }

    public override func layout() {
      super.layout()
      if contentViews.count == 1, let view = contentViews.first {
        view.frame = bounds
        return
      }
      var y: CGFloat = 0
      for (index, view) in contentViews.enumerated() {
        y += gaps[index]
        let height = view.contentHeight(forWidth: bounds.width)
        view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        y += height
      }
    }

    private static func gaps(between blocks: [MarkdownBlock], viewCount: Int, theme: MarkdownTheme) -> [CGFloat] {
      guard viewCount == blocks.count else { return Array(repeating: 0, count: viewCount) }
      return blocks.indices.map { index in
        index == 0 ? 0 : theme.blockGap(after: blocks[index - 1].role, before: blocks[index].role)
      }
    }

    private func makeContentViews(
      blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      streamID: String,
      linkAction: MarkdownLinkAction?,
      imageLoader: MarkdownImageLoader
    ) -> [NativeMarkdownContentView] {
      if MarkdownTextRunRenderer.canRenderAsTextRun(blocks) {
        return [textContentView(blocks: blocks, theme: theme, streamID: streamID, linkAction: linkAction)]
      }

      return blocks.enumerated().map { index, block in
        let blockID = "\(streamID).\(index)"
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList, .blockQuote:
          return textContentView(blocks: [block], theme: theme, streamID: blockID, linkAction: linkAction)
        case let .list(list):
          precondition(
            MarkdownTextRunRenderer.canRenderFlattenedList(list),
            "Complex lists must be structurally projected before native rendering"
          )
          return textContentView(blocks: [block], theme: theme, streamID: blockID, linkAction: linkAction)
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
            linkAction: linkAction,
            imageLoader: imageLoader
          )
        case .thematicBreak:
          return NativeMarkdownSeparatorView(color: NSColor(theme.tableBorderColor))
        }
      }
    }
  }

  @MainActor
  private func textContentView(
    blocks: [MarkdownBlock],
    theme: MarkdownTheme,
    streamID: String,
    linkAction: MarkdownLinkAction?
  ) -> NativeMarkdownContentView {
    StaticMarkdownTextContentView(blocks: blocks, theme: theme, streamID: streamID, linkAction: linkAction)
  }

  @MainActor
  class NativeMarkdownContentView: NSView {
    var onContentChange: (() -> Void)?
    var linkAction: MarkdownLinkAction? {
      didSet { linkActionDidChange() }
    }
    func linkActionDidChange() {}
    var tableBleedLimit: CGFloat = .greatestFiniteMagnitude {
      didSet { tableBleedLimitDidChange() }
    }
    func tableBleedLimitDidChange() {}
    func contentHeight(forWidth _: CGFloat) -> CGFloat { 1 }
    var isContentReady: Bool { true }
  }

  @MainActor
  private final class NativeMarkdownSeparatorView: NativeMarkdownContentView {
    private let ruleColor: NSColor

    init(color: NSColor) {
      ruleColor = color
      super.init(frame: .zero)
      wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
      super.updateLayer()
      layer?.backgroundColor = ruleColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      needsDisplay = true
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
