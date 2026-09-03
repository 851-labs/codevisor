#if canImport(AppKit)
  import AppKit

  /// Owner of a text selection that spans many transcript text views.
  ///
  /// The virtualized transcript adopts this. Surfaces find it by walking their
  /// superview chain, hand it every primary-button click that is not on a
  /// link, and forward the drag that follows. A secondary click off a link
  /// asks it for a menu before `NSTextView` can react, so the transcript-wide
  /// selection is never disturbed. Everything else — native link clicks,
  /// clicks the coordinator declines — stays with `NSTextView`.
  @MainActor
  public protocol TranscriptSelectionCoordinating: AnyObject {
    /// Returns true when the coordinator took the click. The surface then
    /// forwards the remaining `mouseDragged`/`mouseUp` events instead of
    /// running its own selection tracking.
    func beginTranscriptSelection(with event: NSEvent, in surface: NSTextView) -> Bool
    func continueTranscriptSelection(with event: NSEvent)
    func endTranscriptSelection(with event: NSEvent)
    /// Called before a surface falls back to native tracking so a stale
    /// transcript-wide highlight never coexists with a native selection.
    func clearTranscriptSelection()
    /// The context menu for a secondary click at `event` on `surface`, or nil
    /// to use the surface's own. The coordinator may move its selection to
    /// what the click hit first, as native text views do.
    func transcriptSelectionMenu(for surface: NSTextView, with event: NSEvent) -> NSMenu?
  }

  extension NSView {
    /// The nearest ancestor coordinating transcript-wide selection.
    public var transcriptSelectionCoordinator: TranscriptSelectionCoordinating? {
      var ancestor = superview
      while let view = ancestor {
        if let coordinator = view as? TranscriptSelectionCoordinating { return coordinator }
        ancestor = view.superview
      }
      return nil
    }
  }

  /// A read-only transcript text view that can show one slice of a
  /// transcript-wide selection.
  ///
  /// Selection state lives in the coordinator, not in `selectedRange()`:
  /// AppKit paints a non-first-responder selection in the inactive gray, and
  /// only one view can be first responder, so a native range per view could
  /// never look like one continuous selection. The highlight here is drawn
  /// underneath the glyphs with the same geometry AppKit uses for a native
  /// selection, on whichever TextKit generation the view runs. Nothing in
  /// this class reads `layoutManager` unless the view is already TextKit 1,
  /// so TextKit 2 surfaces keep their viewport layout.
  @MainActor
  open class TranscriptSurfaceTextView: NSTextView {
    /// The slice of this view's text covered by the transcript selection.
    public var transcriptSelectionHighlight: NSRange? {
      didSet {
        guard transcriptSelectionHighlight != oldValue else { return }
        needsDisplay = true
      }
    }

    private var isForwardingTranscriptSelection = false

    // MARK: Mouse routing

    /// Subclasses override the `native*` hooks rather than the AppKit
    /// entry points so that routing to the coordinator happens exactly once
    /// per event.
    public final override func mouseDown(with event: NSEvent) {
      if event.modifierFlags.contains(.control), presentTranscriptSelectionMenu(for: event) {
        return
      }
      if routeTranscriptSelectionMouseDown(event) { return }
      nativeMouseDown(with: event)
    }

    /// `NSTextView` answers a secondary click by making itself first
    /// responder and moving its own selection to the word under the pointer
    /// before it ever asks `menu(for:)`. The transcript coordinator drops its
    /// selection the moment focus leaves it, so by the time the menu is
    /// built there is nothing left to copy. Present the coordinator's menu
    /// here instead, without giving `NSTextView` a turn.
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

    open func nativeMouseDown(with event: NSEvent) {
      super.mouseDown(with: event)
    }

    open func nativeMouseDragged(with event: NSEvent) {
      super.mouseDragged(with: event)
    }

    open func nativeMouseUp(with event: NSEvent) {
      super.mouseUp(with: event)
    }

    /// Whether `point` (in view coordinates) is on a link that native
    /// `NSTextView` handling should own. The default checks the attributes
    /// around the insertion index; TextKit 1 subclasses can hit-test glyph
    /// bounds precisely.
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

    /// Shows the coordinator's menu for `event` and returns true, or returns
    /// false when the click is on a link or the coordinator declines it.
    private func presentTranscriptSelectionMenu(for event: NSEvent) -> Bool {
      guard let coordinator = transcriptSelectionCoordinator,
        !transcriptLinkHitTest(at: convert(event.locationInWindow, from: nil)),
        let menu = coordinator.transcriptSelectionMenu(for: self, with: event)
      else { return false }
      popUpTranscriptSelectionMenu(menu, with: event)
      return true
    }

    /// The one place a transcript selection menu is put on screen. Tests
    /// override this because a real pop-up runs its own tracking loop.
    open func popUpTranscriptSelectionMenu(_ menu: NSMenu, with event: NSEvent) {
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    open override func menu(for event: NSEvent) -> NSMenu? {
      transcriptSelectionCoordinator?.transcriptSelectionMenu(for: self, with: event)
        ?? super.menu(for: event)
    }

    // MARK: Selection text

    /// The plain text a copy of `range` should produce. Surfaces whose
    /// storage is not literally what the user reads (tables) override this.
    open func transcriptPlainText(in range: NSRange) -> String {
      guard let textStorage else { return "" }
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
      guard clamped.length > 0 else { return "" }
      return (textStorage.string as NSString).substring(with: clamped)
    }

    // MARK: Highlight drawing

    open override func draw(_ dirtyRect: NSRect) {
      drawTranscriptSelectionHighlight()
      super.draw(dirtyRect)
    }

    private func drawTranscriptSelectionHighlight() {
      guard let range = transcriptSelectionHighlight,
        let textStorage, let textContainer
      else { return }
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
      guard clamped.length > 0 else { return }

      let isEmphasized = window?.isKeyWindow ?? false
      let color =
        isEmphasized
        ? NSColor.selectedTextBackgroundColor
        : NSColor.unemphasizedSelectedTextBackgroundColor
      color.setFill()
      let origin = textContainerOrigin

      if let textLayoutManager {
        let documentStart = textLayoutManager.documentRange.location
        guard
          let start = textLayoutManager.location(documentStart, offsetBy: clamped.location),
          let end = textLayoutManager.location(documentStart, offsetBy: NSMaxRange(clamped)),
          let textRange = NSTextRange(location: start, end: end)
        else { return }
        textLayoutManager.enumerateTextSegments(
          in: textRange,
          type: .selection,
          options: []
        ) { _, frame, _, _ in
          frame.offsetBy(dx: origin.x, dy: origin.y).fill()
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
          rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
      }
    }
  }
#endif
