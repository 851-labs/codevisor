#if canImport(AppKit)
  import AppKit

  @MainActor
  public final class SettledMarkdownDocumentView: NSView {
    private struct ContentKey: Equatable {
      let fragments: [MarkdownFragment]
      let themeFingerprint: Int
      let streamID: String
      let imageLoaderID: String
      let chrome: MarkdownBlockChrome
    }

    private struct Placement {
      let gapAbove: CGFloat
      let indent: CGFloat
      let gapBelow: CGFloat
    }

    public var onContentHeightChange: (() -> Void)?
    public var tableBleedLimit: CGFloat = .greatestFiniteMagnitude {
      didSet { fragmentViews.forEach { $0.tableBleedLimit = tableBleedLimit } }
    }
    private var fragments: [MarkdownFragment] = []
    private var contentKey: ContentKey?
    private var placements: [Placement] = []
    private var fragmentViews: [SettledMarkdownView] = []
    private var theme = MarkdownTheme.default
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1

    public override var isFlipped: Bool { true }

    public var isContentReady: Bool { fragmentViews.allSatisfy(\.isContentReady) }

    public override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public func setContent(
      fragments: [MarkdownFragment],
      theme: MarkdownTheme,
      streamID: String,
      linkAction: MarkdownLinkAction?,
      imageLoader: MarkdownImageLoader = .remote,
      chrome: MarkdownBlockChrome = .standard
    ) {
      precondition(!fragments.isEmpty, "Settled Markdown requires at least one fragment")
      let key = ContentKey(
        fragments: fragments, themeFingerprint: theme.renderFingerprint, streamID: streamID,
        imageLoaderID: imageLoader.id, chrome: chrome)
      if fragments.count != fragmentViews.count { replaceFragmentViews(count: fragments.count) }
      for (index, view) in fragmentViews.enumerated() {
        view.setContent(
          fragment: fragments[index], theme: theme, streamID: "\(streamID).f\(index)", linkAction: linkAction,
          imageLoader: imageLoader, chrome: chrome)
      }
      guard key != contentKey else { return }

      contentKey = key
      self.fragments = fragments
      self.theme = theme
      placements = Self.placements(of: fragments, theme: theme)
      invalidateMeasurement()
    }

    public func contentHeight(forWidth proposedWidth: CGFloat) -> CGFloat {
      let width = max(1, proposedWidth)
      if abs(measuredWidth - width) <= 0.25 { return measuredHeight }
      measuredWidth = width
      measuredHeight = max(1, frames(forWidth: width).last?.maxY ?? 1)
      return measuredHeight
    }

    public func remeasureTableBleed() {
      fragmentViews.forEach { $0.remeasureTableBleed() }
    }

    public override func layout() {
      super.layout()
      for (view, frame) in zip(fragmentViews, frames(forWidth: bounds.width)) {
        view.frame = frame
      }
    }

    public override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      for (index, view) in fragmentViews.enumerated() {
        guard let layout = fragments[index].layout else { continue }

        let decoration = NSRect(
          x: 0, y: view.frame.minY, width: bounds.width, height: view.frame.height + placements[index].gapBelow)
        MarkdownFragmentDecoration.draw(layout, theme: theme, in: decoration)
      }
    }

    private func frames(forWidth width: CGFloat) -> [NSRect] {
      var y: CGFloat = 0
      return zip(fragmentViews, placements).map { view, placement in
        let contentWidth = max(1, width - placement.indent)
        y += placement.gapAbove
        let frame = NSRect(
          x: placement.indent, y: y, width: contentWidth, height: view.contentHeight(forWidth: contentWidth))
        y = frame.maxY + placement.gapBelow
        return frame
      }
    }

    private func replaceFragmentViews(count: Int) {
      fragmentViews.forEach { $0.removeFromSuperview() }
      fragmentViews = (0..<count).map { _ in makeFragmentView() }
    }

    private func makeFragmentView() -> SettledMarkdownView {
      let view = SettledMarkdownView(frame: .zero)
      view.tableBleedLimit = tableBleedLimit
      view.onContentHeightChange = { [weak self] in self?.fragmentContentDidChange() }
      addSubview(view)
      return view
    }

    private func fragmentContentDidChange() {
      invalidateMeasurement()
      invalidateIntrinsicContentSize()
      onContentHeightChange?()
    }

    private func invalidateMeasurement() {
      measuredWidth = -1
      needsLayout = true
      needsDisplay = true
    }

    private static func placements(of fragments: [MarkdownFragment], theme: MarkdownTheme) -> [Placement] {
      fragments.map { fragment in
        Placement(
          gapAbove: theme.gap(above: fragment),
          indent: MarkdownFragmentMetrics.contentIndent(of: fragment.layout),
          gapBelow: fragment.layout.map { theme.gap($0.trailingSpacing) } ?? 0
        )
      }
    }
  }
#endif
