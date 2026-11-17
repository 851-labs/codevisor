#if canImport(AppKit)
  import AppKit

  @MainActor
  final class StaticMarkdownTextContentView: NativeMarkdownContentView {
    private struct ShownText {
      let key: StaticTextKey
      let prepared: PreparedStaticText
    }

    private let surface = StaticTextSurfaceView()
    private let blocks: [MarkdownBlock]
    private let theme: MarkdownTheme
    private let identity: Int
    private lazy var attributedText = Self.attributedText(blocks: blocks, theme: theme)
    private var shown: ShownText?

    override var isContentReady: Bool { shown != nil }

    override var isFlipped: Bool { true }

    init(blocks: [MarkdownBlock], theme: MarkdownTheme, streamID: String, linkAction: MarkdownLinkAction?) {
      self.blocks = blocks
      self.theme = theme
      identity = Self.identity(blocks: blocks, theme: theme, streamID: streamID)
      super.init(frame: .zero)
      self.linkAction = linkAction
      surface.linkAction = linkAction
      addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func linkActionDidChange() {
      surface.linkAction = linkAction
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
      text(atWidth: width).size.height
    }

    override func layout() {
      super.layout()
      surface.frame = bounds
      showText()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window == nil else {
        needsLayout = true
        return
      }
      shown = nil
    }

    override func viewDidEndLiveResize() {
      super.viewDidEndLiveResize()
      guard let shown else { return }
      StaticTextCache.shared.store(shown.prepared, for: shown.key)
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      showText()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      showText()
    }

    static func prefetch(
      blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      streamID: String,
      width: CGFloat,
      scale: CGFloat,
      appearance: NSAppearance.Name
    ) {
      let request = makeRequest(
        identity: identity(blocks: blocks, theme: theme, streamID: streamID),
        blocks: blocks, theme: theme, width: width, scale: scale, appearance: appearance)
      guard StaticTextCache.shared.cached(request.key) == nil else { return }
      StaticTextCache.shared.startPreparing(request)
    }

    private func showText() {
      guard bounds.width > 1 else { return }
      let wasReady = isContentReady
      surface.show(text(atWidth: bounds.width))
      if !wasReady { onContentChange?() }
    }

    private func text(atWidth width: CGFloat) -> PreparedStaticText {
      let request = request(forWidth: width)
      if let shown, shown.key == request.key { return shown.prepared }
      let prepared = StaticTextCache.shared.cached(request.key) ?? preparedNow(request)
      shown = ShownText(key: request.key, prepared: prepared)
      return prepared
    }

    private func preparedNow(_ request: StaticTextRequest) -> PreparedStaticText {
      let prepared = PreparedStaticText.preparedNow(request, text: attributedText)
      if !inLiveResize { StaticTextCache.shared.store(prepared, for: request.key) }
      return prepared
    }

    private func request(forWidth width: CGFloat) -> StaticTextRequest {
      Self.makeRequest(
        identity: identity, blocks: blocks, theme: theme, width: width,
        scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
        appearance: effectiveAppearance.name)
    }

    private static func makeRequest(
      identity: Int,
      blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      width: CGFloat,
      scale: CGFloat,
      appearance: NSAppearance.Name
    ) -> StaticTextRequest {
      StaticTextRequest(
        identity: identity, layout: .wrapping(width: width, inset: 0), scale: scale, appearance: appearance
      ) {
        attributedText(blocks: blocks, theme: theme)
      }
    }

    private nonisolated static func attributedText(
      blocks: [MarkdownBlock], theme: MarkdownTheme
    ) -> NSAttributedString {
      MarkdownTextRunRenderer.attributedString(for: blocks, theme: theme, foregroundColor: theme.textForeground)
    }

    private static func identity(blocks: [MarkdownBlock], theme: MarkdownTheme, streamID: String) -> Int {
      var hasher = Hasher()
      hasher.combine(streamID)
      hasher.combine(blocks)
      hasher.combine(theme.renderFingerprint)
      return hasher.finalize()
    }
  }
#endif
