#if canImport(AppKit)
  import AppKit
  import SwiftUI

  @MainActor
  final class NativeMarkdownCodeBlockView: NativeMarkdownContentView {
    override var isFlipped: Bool { true }

    private static let headerHeight: CGFloat = 27
    private static let dividerHeight: CGFloat = 1
    private static let contentInset: CGFloat = 10

    private let id: String
    private let language: String?
    private let code: String
    private let theme: MarkdownTheme
    private let languageLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let divider = NSBox()
    private let fillColor: NSColor
    private let scrollView = TranscriptHorizontalScrollView()
    private let staticSurface = StaticTextSurfaceView()
    private var staticPreparation: Task<Void, Never>?
    private var staticText: (text: AttributedString, isHighlighted: Bool)?
    private var highlightTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?
    private var contentSize = CGSize(width: 1, height: 1)
    private(set) var measurementCount = 0

    init(id: String, language: String?, code: String, theme: MarkdownTheme) {
      self.id = id
      self.language = language
      self.code = code
      self.theme = theme
      fillColor = NSColor(theme.codeBackground)
      super.init(frame: .zero)
      configureChrome()
      installInitialText()
      beginHighlightingIfNeeded()
    }

    deinit {
      highlightTask?.cancel()
      copyResetTask?.cancel()
      staticPreparation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var isContentReady: Bool { staticSurface.prepared != nil }

    override func contentHeight(forWidth _: CGFloat) -> CGFloat {
      if staticSurface.prepared == nil, let staticText {
        install(staticText.text, isHighlighted: staticText.isHighlighted)
      }
      return Self.headerHeight + Self.dividerHeight + contentSize.height
    }

    override func layout() {
      super.layout()
      let header = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
      languageLabel.sizeToFit()
      languageLabel.frame.origin = NSPoint(
        x: Self.contentInset,
        y: floor((header.height - languageLabel.frame.height) / 2)
      )
      copyButton.sizeToFit()
      copyButton.frame.origin = NSPoint(
        x: max(Self.contentInset, bounds.width - Self.contentInset - copyButton.frame.width),
        y: floor((header.height - copyButton.frame.height) / 2)
      )
      divider.frame = NSRect(
        x: 0,
        y: header.maxY,
        width: bounds.width,
        height: Self.dividerHeight
      )
      scrollView.frame = NSRect(
        x: 0,
        y: divider.frame.maxY,
        width: bounds.width,
        height: contentSize.height
      )
      staticSurface.frame = NSRect(origin: .zero, size: contentSize)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
      super.updateLayer()
      layer?.backgroundColor = fillColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      needsDisplay = true
    }

    private func configureChrome() {
      wantsLayer = true
      layer?.cornerRadius = 8
      layer?.masksToBounds = true

      languageLabel.stringValue = language?.uppercased() ?? "CODE"
      languageLabel.font = .systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
        weight: .semibold
      )
      languageLabel.textColor = .secondaryLabelColor

      copyButton.title = "Copy"
      copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
      copyButton.imagePosition = .imageLeading
      copyButton.isBordered = false
      copyButton.font = .preferredFont(forTextStyle: .caption2)
      copyButton.contentTintColor = .secondaryLabelColor
      copyButton.target = self
      copyButton.action = #selector(copyCode)
      copyButton.toolTip = "Copy code"

      divider.boxType = .separator
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      scrollView.hasHorizontalScroller = false
      scrollView.hasVerticalScroller = false
      scrollView.horizontalScrollElasticity = .automatic
      scrollView.verticalScrollElasticity = .none
      scrollView.documentView = staticSurface

      addSubview(languageLabel)
      addSubview(copyButton)
      addSubview(divider)
      addSubview(scrollView)
    }

    private func installInitialText() {
      let key = CodeHighlightResultCache.Key(
        themeKey: theme.codeThemeKey,
        language: language,
        code: code
      )
      let highlighted = CodeHighlightResultCache.shared.value(for: key)
      install(highlighted ?? AttributedString(code), isHighlighted: highlighted != nil)
    }

    private func beginHighlightingIfNeeded() {
      guard let highlighter = theme.codeHighlighter else { return }
      let key = CodeHighlightResultCache.Key(
        themeKey: theme.codeThemeKey,
        language: language,
        code: code
      )
      guard CodeHighlightResultCache.shared.value(for: key) == nil else { return }
      let request = CodeHighlightRequest(
        id: id,
        code: code,
        language: language,
        isComplete: true
      )
      highlightTask = Task { @MainActor [weak self] in
        guard let highlighted = await highlighter(request), !Task.isCancelled else { return }
        CodeHighlightResultCache.shared.store(highlighted, for: key)
        self?.install(highlighted)
      }
    }

    func install(_ text: AttributedString, isHighlighted: Bool = true) {
      staticText = (text, isHighlighted)
      let surface = staticSurface
      let request = staticRequest(for: text, isHighlighted: isHighlighted)
      if let prepared = StaticTextCache.shared.cached(request.key) {
        showStatic(prepared, in: surface)
        return
      }
      if contentSize.height <= 1 {
        contentSize = CGSize(width: max(1, bounds.width), height: StaticTextEstimate.height(ofCode: code))
      }
      let preparation = StaticTextCache.shared.startPreparing(request)
      staticPreparation?.cancel()
      staticPreparation = Task { [weak self, weak surface] in
        guard let prepared = await preparation.value, !Task.isCancelled,
          let self, let surface
        else { return }
        self.showStatic(prepared, in: surface)
        self.onContentChange?()
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil, staticSurface.prepared == nil, let staticText else { return }
      install(staticText.text, isHighlighted: staticText.isHighlighted)
    }

    private func showStatic(_ prepared: PreparedStaticText, in surface: StaticTextSurfaceView) {
      surface.show(prepared)
      guard prepared.size != contentSize else { return }
      contentSize = prepared.size
      measurementCount += 1
      needsLayout = true
    }

    private func staticRequest(for text: AttributedString, isHighlighted: Bool) -> StaticTextRequest {
      Self.staticRequest(
        id: id, code: code, text: text, isHighlighted: isHighlighted, theme: theme,
        scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
        appearance: effectiveAppearance.name)
    }

    static func prefetch(
      id: String, language: String?, code: String, theme: MarkdownTheme, scale: CGFloat, appearance: NSAppearance.Name
    ) {
      let key = CodeHighlightResultCache.Key(themeKey: theme.codeThemeKey, language: language, code: code)
      let highlighted = CodeHighlightResultCache.shared.value(for: key)
      let request = staticRequest(
        id: id, code: code, text: highlighted ?? AttributedString(code), isHighlighted: highlighted != nil,
        theme: theme, scale: scale, appearance: appearance)
      guard StaticTextCache.shared.cached(request.key) == nil else { return }
      StaticTextCache.shared.startPreparing(request)
    }

    private static func staticRequest(
      id: String,
      code: String,
      text: AttributedString,
      isHighlighted: Bool,
      theme: MarkdownTheme,
      scale: CGFloat,
      appearance: NSAppearance.Name
    ) -> StaticTextRequest {
      var hasher = Hasher()
      hasher.combine(id)
      hasher.combine(code)
      hasher.combine(isHighlighted)
      hasher.combine(theme.renderFingerprint)
      let foreground = theme.codeForeground
      return StaticTextRequest(
        identity: hasher.finalize(),
        layout: .natural(inset: contentInset),
        scale: scale,
        appearance: appearance
      ) {
        nativeCodeAttributedString(text, foreground: NSColor(foreground))
      }
    }

    @objc private func copyCode() {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(code, forType: .string)
      copyButton.title = "Copied"
      copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
      copyResetTask?.cancel()
      copyResetTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        self?.copyButton.title = "Copy"
        self?.copyButton.image = NSImage(
          systemSymbolName: "doc.on.doc",
          accessibilityDescription: nil
        )
      }
    }
  }
#endif
