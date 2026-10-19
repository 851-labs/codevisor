#if canImport(AppKit)
  import AppKit

  @MainActor
  public protocol TranscriptSelectionCoordinating: AnyObject {
    func beginTranscriptSelection(with event: NSEvent, in surface: NSTextView) -> Bool
    func continueTranscriptSelection(with event: NSEvent)
    func endTranscriptSelection(with event: NSEvent)
    func clearTranscriptSelection()
    func transcriptSelectionMenu(for surface: NSTextView, with event: NSEvent) -> NSMenu?
  }

  extension NSView {
    public var transcriptSelectionCoordinator: TranscriptSelectionCoordinating? {
      var ancestor = superview
      while let view = ancestor {
        if let coordinator = view as? TranscriptSelectionCoordinating { return coordinator }
        ancestor = view.superview
      }
      return nil
    }
  }

  @MainActor
  open class TranscriptSurfaceTextView: NSTextView {
    var linkAction: MarkdownLinkAction?

    public var transcriptSelectionHighlight: NSRange? {
      didSet {
        guard transcriptSelectionHighlight != oldValue else { return }
        needsDisplay = true
      }
    }

    public var transcriptFindHighlights: TranscriptFindHighlights? {
      didSet {
        guard transcriptFindHighlights != oldValue else { return }
        needsDisplay = true
      }
    }

    private var isForwardingTranscriptSelection = false
    private var isPointerRefreshScheduled = false

    public final override func mouseDown(with event: NSEvent) {
      if event.modifierFlags.contains(.control), presentTranscriptSelectionMenu(for: event) {
        return
      }
      if routeTranscriptSelectionMouseDown(event) { return }
      nativeMouseDown(with: event)
    }

    public final override func rightMouseDown(with event: NSEvent) {
      if presentTranscriptSelectionMenu(for: event) { return }
      super.rightMouseDown(with: event)
    }

    public final override func mouseDragged(with event: NSEvent) {
      if isForwardingTranscriptSelection {
        transcriptSelectionCoordinator?.continueTranscriptSelection(with: event)
        return
      }
      nativeMouseDragged(with: event)
    }

    public final override func mouseUp(with event: NSEvent) {
      if isForwardingTranscriptSelection {
        isForwardingTranscriptSelection = false
        transcriptSelectionCoordinator?.endTranscriptSelection(with: event)
        return
      }
      nativeMouseUp(with: event)
    }

    open override func mouseMoved(with event: NSEvent) {
      guard unoccludedLocation(of: event) != nil else { return }
      super.mouseMoved(with: event)
    }

    open override func cursorUpdate(with event: NSEvent) {
      guard unoccludedLocation(of: event) != nil else { return }
      super.cursorUpdate(with: event)
    }

    func unoccludedLocation(of event: NSEvent) -> NSPoint? {
      guard let hit = window?.contentView?.hitTest(event.locationInWindow),
        hit === self || hit.isDescendant(of: self)
      else { return nil }
      return convert(event.locationInWindow, from: nil)
    }

    open override func updateTrackingAreas() {
      super.updateTrackingAreas()
      guard !isPointerRefreshScheduled, let window,
        visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
      else { return }
      isPointerRefreshScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.isPointerRefreshScheduled = false
        self.replayPointerMove()
      }
    }

    private func replayPointerMove() {
      guard let window, window.isKeyWindow, NSEvent.pressedMouseButtons == 0,
        let move = NSEvent.mouseEvent(
          with: .mouseMoved,
          location: window.mouseLocationOutsideOfEventStream,
          modifierFlags: NSEvent.modifierFlags,
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber,
          context: nil,
          eventNumber: 0,
          clickCount: 0,
          pressure: 0
        )
      else { return }
      mouseMoved(with: move)
    }

    open func nativeMouseDown(with event: NSEvent) {
      super.mouseDown(with: event)
    }

    open func nativeMouseDragged(with event: NSEvent) {
      super.mouseDragged(with: event)
    }

    open func nativeMouseUp(with event: NSEvent) {
      super.mouseUp(with: event)
    }

    open func transcriptLinkHitTest(at point: NSPoint) -> Bool {
      guard let textStorage, textStorage.length > 0 else { return false }
      let index = characterIndexForInsertion(at: point)
      guard index != NSNotFound else { return false }
      for candidate in [index, index - 1] where candidate >= 0 && candidate < textStorage.length {
        let attributes = textStorage.attributes(at: candidate, effectiveRange: nil)
        if attributes[.link] != nil || attributes[.streamMarkdownServerFileLink] != nil {
          return true
        }
      }
      return false
    }

    private func routeTranscriptSelectionMouseDown(_ event: NSEvent) -> Bool {
      isForwardingTranscriptSelection = false
      guard event.type == .leftMouseDown,
        !event.modifierFlags.contains(.control),
        let coordinator = transcriptSelectionCoordinator
      else { return false }
      let point = convert(event.locationInWindow, from: nil)
      if transcriptLinkHitTest(at: point) {
        coordinator.clearTranscriptSelection()
        return false
      }
      guard coordinator.beginTranscriptSelection(with: event, in: self) else { return false }
      isForwardingTranscriptSelection = true
      return true
    }

    private func presentTranscriptSelectionMenu(for event: NSEvent) -> Bool {
      guard let coordinator = transcriptSelectionCoordinator,
        !transcriptLinkHitTest(at: convert(event.locationInWindow, from: nil)),
        let menu = coordinator.transcriptSelectionMenu(for: self, with: event)
      else { return false }
      popUpTranscriptSelectionMenu(menu, with: event)
      return true
    }

    open func popUpTranscriptSelectionMenu(_ menu: NSMenu, with event: NSEvent) {
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    open override func menu(for event: NSEvent) -> NSMenu? {
      let point = convert(event.locationInWindow, from: nil)
      if let menu = markdownImageMenu(at: point) ?? markdownWebLinkMenu(at: point) { return menu }
      return transcriptSelectionCoordinator?.transcriptSelectionMenu(for: self, with: event)
        ?? super.menu(for: event)
    }

    open func transcriptPlainText(in range: NSRange) -> String {
      guard let textStorage else { return "" }
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
      guard clamped.length > 0 else { return "" }
      return (textStorage.string as NSString).substring(with: clamped)
    }

    open override func draw(_ dirtyRect: NSRect) {
      drawTranscriptFindHighlights()
      drawTranscriptSelectionHighlight()
      super.draw(dirtyRect)
    }

    private func drawTranscriptSelectionHighlight() {
      guard let range = transcriptSelectionHighlight else { return }
      let isEmphasized = window?.isKeyWindow ?? false
      let color =
        isEmphasized
        ? NSColor.selectedTextBackgroundColor
        : NSColor.unemphasizedSelectedTextBackgroundColor
      color.setFill()
      transcriptTextRects(for: range).forEach { $0.fill() }
    }

    private func drawTranscriptFindHighlights() {
      guard let highlights = transcriptFindHighlights else { return }
      let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      for (index, range) in highlights.ranges.enumerated() {
        let isCurrent = index == highlights.currentIndex
        let color: NSColor =
          isCurrent
          ? NSColor.systemOrange.withAlphaComponent(isDark ? 0.75 : 0.85)
          : NSColor.systemYellow.withAlphaComponent(isDark ? 0.35 : 0.5)
        color.setFill()
        for rect in transcriptTextRects(for: range) {
          NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
      }
    }

    public func transcriptTextRects(for range: NSRange) -> [NSRect] {
      guard let textStorage, let textContainer else { return [] }
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
      guard clamped.length > 0 else { return [] }
      let origin = textContainerOrigin
      var rects: [NSRect] = []

      if let textLayoutManager {
        let documentStart = textLayoutManager.documentRange.location
        guard
          let start = textLayoutManager.location(documentStart, offsetBy: clamped.location),
          let end = textLayoutManager.location(documentStart, offsetBy: NSMaxRange(clamped)),
          let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        textLayoutManager.enumerateTextSegments(
          in: textRange,
          type: .selection,
          options: []
        ) { _, frame, _, _ in
          rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
          return true
        }
      } else if let layoutManager {
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: clamped,
          actualCharacterRange: nil
        )
        layoutManager.enumerateEnclosingRects(
          forGlyphRange: glyphRange,
          withinSelectedGlyphRange: glyphRange,
          in: textContainer
        ) { rect, _ in
          rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
      }
      return rects
    }
  }
#endif
