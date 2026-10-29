#if canImport(AppKit)
  import AppKit

  @MainActor
  final class StaticMarkdownTextContentView: NativeMarkdownContentView {
    private let surface = StaticTextSurfaceView()
    private let blocks: [MarkdownBlock]
    private let theme: MarkdownTheme
    private let identity: Int
    private var requestedKey: StaticTextKey?
    private var preparation: Task<Void, Never>?
    private var lastHeight: CGFloat?
    private var reportedHeight: CGFloat?
    private var preparedKey: StaticTextKey?

    override var isContentReady: Bool { preparedKey != nil && preparedKey == requestedKey }

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

    deinit {
      preparation?.cancel()
    }

    override func linkActionDidChange() {
      surface.linkAction = linkAction
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
      let request = request(forWidth: width)
      if let prepared = StaticTextCache.shared.cached(request.key) {
        requestedKey = request.key
        preparedKey = request.key
        lastHeight = prepared.size.height
        reportedHeight = prepared.size.height
        return prepared.size.height
      }
      beginPreparing(request)
      let height = lastHeight ?? StaticTextEstimate.height(of: blocks, theme: theme, width: width)
      reportedHeight = height
      return height
    }

    override func layout() {
      super.layout()
      surface.frame = bounds
      showPreparedText(forWidth: bounds.width)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window == nil else {
        needsLayout = true
        return
      }
      preparation?.cancel()
      requestedKey = nil
      preparedKey = nil
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      showPreparedText(forWidth: bounds.width)
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      showPreparedText(forWidth: bounds.width)
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

    private func showPreparedText(forWidth width: CGFloat) {
      guard width > 1 else { return }
      let request = request(forWidth: width)
      guard let prepared = StaticTextCache.shared.cached(request.key) else {
        beginPreparing(request)
        return
      }
      requestedKey = request.key
      preparedKey = request.key
      surface.show(prepared)
      if let reportedHeight, reportedHeight != prepared.size.height {
        lastHeight = prepared.size.height
        onContentChange?()
      }
    }

    private func beginPreparing(_ request: StaticTextRequest) {
      guard requestedKey != request.key else { return }
      requestedKey = request.key
      let task = StaticTextCache.shared.startPreparing(request)
      preparation?.cancel()
      preparation = Task { [weak self] in
        guard let prepared = await task.value, !Task.isCancelled else { return }
        self?.didPrepare(prepared, for: request.key)
      }
    }

    private func didPrepare(_ prepared: PreparedStaticText, for key: StaticTextKey) {
      guard key == requestedKey else { return }
      preparedKey = key
      lastHeight = prepared.size.height
      surface.show(prepared)
      onContentChange?()
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
        MarkdownTextRunRenderer.attributedString(for: blocks, theme: theme, foregroundColor: theme.textForeground)
      }
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
