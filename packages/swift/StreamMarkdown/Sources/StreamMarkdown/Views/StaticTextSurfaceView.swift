#if canImport(AppKit)
  import AppKit

  @MainActor
  public final class StaticTextSurfaceView: NSView, TranscriptTextSurface {
    var linkAction: MarkdownLinkAction? {
      didSet { liveView?.linkAction = linkAction }
    }
    private(set) var prepared: PreparedStaticText?
    private(set) var liveView: SelectableTextKitView?
    private let textLayer = CALayer()
    private let highlights = StaticTextHighlightLayer()
    private var forwardsSelectionToCoordinator = false
    private var forwardsEventsToLiveView = false
    private var hoveredLink: NSRange?

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layerContentsRedrawPolicy = .onSetNeedsDisplay
      textLayer.contentsGravity = .topLeft
      textLayer.anchorPoint = .zero
      textLayer.zPosition = 1
      textLayer.actions = Self.disabledActions
      highlights.actions = Self.disabledActions
      layer?.addSublayer(highlights)
      layer?.addSublayer(textLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func show(_ prepared: PreparedStaticText) {
      guard prepared !== self.prepared else { return }
      detachLiveView()
      self.prepared = prepared
      hoveredLink = nil
      installTextContents()
      redrawHighlights()
      attachLiveViewForAssistiveTechnologies()
    }

    func releaseContents() {
      detachLiveView()
      prepared = nil
      installTextContents()
    }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { releaseContents() }
    }

    public var transcriptText: NSAttributedString { prepared?.text ?? NSAttributedString() }

    public var acceptsTranscriptSelection: Bool { liveView == nil }

    public var transcriptSelectionHighlight: NSRange? {
      didSet {
        guard transcriptSelectionHighlight != oldValue else { return }
        if liveDrawsText { liveView?.transcriptSelectionHighlight = transcriptSelectionHighlight }
        redrawHighlights()
      }
    }

    public var transcriptFindHighlights: TranscriptFindHighlights? {
      didSet {
        guard transcriptFindHighlights != oldValue else { return }
        if liveDrawsText { liveView?.transcriptFindHighlights = transcriptFindHighlights }
        redrawHighlights()
      }
    }

    public func transcriptCharacterIndex(at viewPoint: NSPoint) -> Int {
      guard let prepared else { return 0 }
      return StaticTextHitTesting.insertionIndex(in: prepared, at: viewPoint)
    }

    public func transcriptTextRects(for range: NSRange) -> [NSRect] {
      guard let prepared else { return [] }
      return StaticTextHitTesting.rects(in: prepared, for: range)
    }

    public override func layout() {
      super.layout()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      highlights.frame = bounds
      textLayer.frame = CGRect(origin: .zero, size: prepared?.size ?? .zero)
      CATransaction.commit()
      liveView?.frame = liveFrame
    }

    public override func draw(_ dirtyRect: NSRect) {
      guard let prepared, prepared.image == nil, liveView == nil else { return }
      highlights.drawInline(
        in: prepared, selection: transcriptSelectionHighlight, find: transcriptFindHighlights, hoveredLink: hoveredLink)
      let glyphs = prepared.layout.manager.glyphRange(for: prepared.layout.container)
      let origin = NSPoint(x: prepared.inset, y: prepared.inset)
      prepared.layout.manager.drawBackground(forGlyphRange: glyphs, at: origin)
      prepared.layout.manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    public override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      installTextContents()
    }

    public override func updateTrackingAreas() {
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(
          rect: .zero,
          options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
          owner: self
        ))
      super.updateTrackingAreas()
    }

    public override func cursorUpdate(with event: NSEvent) {
      guard let point = unoccludedLocation(of: event) else { return }
      cursor(at: point).set()
    }

    public override func mouseMoved(with event: NSEvent) {
      guard let point = unoccludedLocation(of: event) else { return updateHoveredLink(nil) }
      cursor(at: point).set()
      updateHoveredLink(StaticTextHitTesting.linkRange(in: prepared, at: point))
    }

    public override func mouseExited(with event: NSEvent) {
      updateHoveredLink(nil)
      guard !forwardsEventsToLiveView else { return }
      detachLiveView()
    }

    public override func mouseDown(with event: NSEvent) {
      forwardsSelectionToCoordinator = false
      forwardsEventsToLiveView = false
      if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
      let point = convert(event.locationInWindow, from: nil)
      if StaticTextHitTesting.link(in: prepared, at: point) != nil {
        transcriptSelectionCoordinator?.clearTranscriptSelection()
        return forwardToLiveView(event) { $0.mouseDown(with: $1) }
      }
      guard let coordinator = transcriptSelectionCoordinator,
        coordinator.beginTranscriptSelection(with: event, in: self)
      else { return }
      forwardsSelectionToCoordinator = true
    }

    public override func mouseDragged(with event: NSEvent) {
      if forwardsSelectionToCoordinator {
        transcriptSelectionCoordinator?.continueTranscriptSelection(with: event)
      } else if forwardsEventsToLiveView {
        liveView?.mouseDragged(with: event)
      }
    }

    public override func mouseUp(with event: NSEvent) {
      if forwardsSelectionToCoordinator {
        forwardsSelectionToCoordinator = false
        transcriptSelectionCoordinator?.endTranscriptSelection(with: event)
        return
      }
      guard forwardsEventsToLiveView else { return }
      forwardsEventsToLiveView = false
      liveView?.mouseUp(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
      forwardToLiveView(event) { $0.rightMouseDown(with: $1) }
    }

    public override func isAccessibilityElement() -> Bool { liveView == nil }

    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    public override func accessibilityValue() -> Any? { transcriptText.string }

    private var liveFrame: NSRect {
      guard let prepared else { return .zero }
      return NSRect(
        x: prepared.inset, y: prepared.inset, width: prepared.layout.size.width, height: prepared.layout.size.height)
    }

    private func installTextContents() {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      textLayer.contents = prepared?.image
      textLayer.contentsScale = prepared?.scale ?? window?.backingScaleFactor ?? 2
      textLayer.isHidden = prepared?.image == nil
      CATransaction.commit()
      needsLayout = true
      needsDisplay = true
    }

    private func redrawHighlights() {
      guard let prepared else { return }
      guard prepared.image != nil else {
        needsDisplay = true
        return
      }
      highlights.update(
        in: prepared,
        selection: transcriptSelectionHighlight,
        find: transcriptFindHighlights,
        hoveredLink: hoveredLink,
        isKeyWindow: window?.isKeyWindow ?? false,
        appearance: effectiveAppearance
      )
    }

    private func cursor(at point: NSPoint) -> NSCursor {
      StaticTextHitTesting.link(in: prepared, at: point) == nil ? .iBeam : .pointingHand
    }

    private func unoccludedLocation(of event: NSEvent) -> NSPoint? {
      guard let hit = window?.contentView?.hitTest(event.locationInWindow),
        hit === self || hit.isDescendant(of: self)
      else { return nil }
      return convert(event.locationInWindow, from: nil)
    }

    private func forwardToLiveView(_ event: NSEvent, deliver: (SelectableTextKitView, NSEvent) -> Void) {
      guard let live = attachLiveView() else { return }
      forwardsEventsToLiveView = event.type == .leftMouseDown
      deliver(live, event)
    }

    @discardableResult
    private func attachLiveView() -> SelectableTextKitView? {
      if let liveView { return liveView }
      guard let prepared else { return nil }
      let live = SelectableTextKitView(preparedLayout: prepared.layout)
      live.drawsGlyphs = liveDrawsText
      live.linkAction = linkAction
      if liveDrawsText {
        live.transcriptSelectionHighlight = transcriptSelectionHighlight
        live.transcriptFindHighlights = transcriptFindHighlights
      }
      live.frame = liveFrame
      liveView = live
      addSubview(live)
      guard liveDrawsText else { return live }
      live.display()
      needsDisplay = true
      displayIfNeeded()
      return live
    }

    private func detachLiveView() {
      guard let liveView, !Self.requiresLiveText else { return }
      liveView.removeFromSuperview()
      self.liveView = nil
      guard prepared?.image == nil else { return }
      needsDisplay = true
      displayIfNeeded()
    }

    private func updateHoveredLink(_ range: NSRange?) {
      guard range != hoveredLink else { return }
      hoveredLink = range
      redrawHighlights()
    }

    private var liveDrawsText: Bool { prepared?.image == nil }

    private static let disabledActions: [String: any CAAction] = Dictionary(
      uniqueKeysWithValues: [
        "contents", "hidden", "bounds", "position", "contentsScale", "opacity", "onOrderIn", "onOrderOut",
      ]
      .map { ($0, NSNull()) })

    private func attachLiveViewForAssistiveTechnologies() {
      guard Self.requiresLiveText else { return }
      attachLiveView()
    }

    private static var requiresLiveText: Bool { NSWorkspace.shared.isVoiceOverEnabled }
  }
#endif
