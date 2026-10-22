#if canImport(AppKit)
  import AppKit
  import QuickLookUI
  import QuartzCore
  import SwiftUI

  @MainActor
  open class TranscriptSelectableTextView: TranscriptSurfaceTextView {
    private struct LinkHit {
      let value: Any
      let range: NSRange
      let isServerFile: Bool
    }

    private struct PendingServerFileLinkClick {
      let value: Any
      let range: NSRange
      let origin: NSPoint
    }

    private var mouseSelectionAnchor: Int?
    private var selectionRepaintTracker = SelectionRepaintTracker()
    private var isTrackingMouseSelection = false
    private var linkHoverTrackingArea: NSTrackingArea?
    private let linkScan = TextStorageLinkScan()
    private var pendingServerFileLinkClick: PendingServerFileLinkClick?
    private(set) var hoveredLinkRange: NSRange?

    public override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
      false
    }

    public override func clicked(onLink link: Any, at charIndex: Int) {
      let isImage = textStorage?.streamMarkdownHasImage(at: charIndex) ?? false
      guard !handleMarkdownLink(link, isImage: isImage, action: linkAction, in: self, at: charIndex) else { return }
      super.clicked(onLink: link, at: charIndex)
    }

    public override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if textStorageContainsLinks {
        guard linkHoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
          rect: .zero,
          options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
          owner: self,
          userInfo: nil
        )
        addTrackingArea(area)
        linkHoverTrackingArea = area
      } else if let linkHoverTrackingArea {
        removeTrackingArea(linkHoverTrackingArea)
        self.linkHoverTrackingArea = nil
        updateLinkHover(at: nil)
      }
    }

    private var textStorageContainsLinks: Bool {
      guard let textStorage, textStorage.length > 0 else { return false }
      return linkScan.containsLinks(in: textStorage)
    }

    public override func mouseMoved(with event: NSEvent) {
      guard !TranscriptPointerTracking.isScrolling(in: window) else { return }
      super.mouseMoved(with: event)
      updateLinkHover(at: unoccludedLocation(of: event))
    }

    public override func mouseEntered(with event: NSEvent) {
      super.mouseEntered(with: event)
      guard !TranscriptPointerTracking.isScrolling(in: window) else { return }
      updateLinkHover(at: unoccludedLocation(of: event))
    }

    public override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      updateLinkHover(at: nil)
    }

    public override func nativeMouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      if event.clickCount == 1,
        event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
        let hit = linkHit(at: point), hit.isServerFile
      {
        pendingServerFileLinkClick = PendingServerFileLinkClick(
          value: hit.value,
          range: hit.range,
          origin: point
        )
      } else {
        pendingServerFileLinkClick = nil
      }

      selectionRepaintTracker.begin(with: selectedRange())
      isTrackingMouseSelection = true
      if event.clickCount == 1,
        event.modifierFlags.intersection([.shift, .command, .option]).isEmpty
      {
        mouseSelectionAnchor = characterIndexForInsertion(at: point)
      } else {
        mouseSelectionAnchor = nil
      }

      super.nativeMouseDown(with: event)

      correctVisualLineEndSelection(at: currentMouseLocation)
      if NSEvent.pressedMouseButtons & 1 == 0 {
        finishMouseSelectionRepaint()
        mouseSelectionAnchor = nil
        activatePendingServerFileLink(at: currentMouseLocation)
      }
    }

    public override func nativeMouseDragged(with event: NSEvent) {
      super.nativeMouseDragged(with: event)
      let point = convert(event.locationInWindow, from: nil)
      correctVisualLineEndSelection(at: point)
      cancelPendingServerFileLinkIfDragged(to: point)
    }

    public override func nativeMouseUp(with event: NSEvent) {
      super.nativeMouseUp(with: event)
      let point = convert(event.locationInWindow, from: nil)
      correctVisualLineEndSelection(at: point)
      finishMouseSelectionRepaint()
      mouseSelectionAnchor = nil
      activatePendingServerFileLink(at: point)
    }

    public override func setSelectedRange(
      _ charRange: NSRange,
      affinity: NSSelectionAffinity,
      stillSelecting stillSelectingFlag: Bool
    ) {
      let removedRanges =
        isTrackingMouseSelection
        ? selectionRepaintTracker.record(charRange)
        : []
      super.setSelectedRange(
        charRange,
        affinity: affinity,
        stillSelecting: stillSelectingFlag
      )

      for range in removedRanges {
        repaintRemovedSelection(range, immediately: true)
      }
    }

    public override func resignFirstResponder() -> Bool {
      let didResign = super.resignFirstResponder()
      guard didResign else { return false }

      let selection = selectedRange()
      if selection.length > 0 {
        setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
        repaintRemovedSelection(selection)
      }
      return true
    }

    func updateLinkHover(at point: NSPoint?) {
      let nextRange = point.flatMap(linkRange(at:))
      guard nextRange != hoveredLinkRange else { return }

      if let hoveredLinkRange {
        layoutManager?.removeTemporaryAttribute(
          .underlineStyle,
          forCharacterRange: hoveredLinkRange
        )
      }
      hoveredLinkRange = nextRange
      if let nextRange {
        layoutManager?.addTemporaryAttribute(
          .underlineStyle,
          value: NSUnderlineStyle.single.rawValue,
          forCharacterRange: nextRange
        )
      }
    }

    private func linkRange(at viewPoint: NSPoint) -> NSRange? {
      linkHit(at: viewPoint)?.range
    }

    public override func transcriptLinkHitTest(at point: NSPoint) -> Bool {
      linkHit(at: point) != nil
    }

    private func linkHit(at viewPoint: NSPoint) -> LinkHit? {
      guard let layoutManager, let textContainer, let textStorage,
        textStorage.length > 0, layoutManager.numberOfGlyphs > 0
      else { return nil }

      let origin = textContainerOrigin
      let point = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
      let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
      guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

      let glyphRect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyphIndex, length: 1),
        in: textContainer
      )
      guard glyphRect.contains(point) else { return nil }

      let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
      guard characterIndex < textStorage.length else { return nil }
      var effectiveRange = NSRange()
      if let value = textStorage.attribute(
        .streamMarkdownServerFileLink,
        at: characterIndex,
        effectiveRange: &effectiveRange
      ) {
        return LinkHit(value: value, range: effectiveRange, isServerFile: true)
      }
      guard
        let value = textStorage.attribute(
          .link,
          at: characterIndex,
          effectiveRange: &effectiveRange
        )
      else { return nil }
      return LinkHit(value: value, range: effectiveRange, isServerFile: false)
    }

    private func cancelPendingServerFileLinkIfDragged(to point: NSPoint) {
      guard let pendingServerFileLinkClick else { return }
      let delta = NSPoint(
        x: point.x - pendingServerFileLinkClick.origin.x,
        y: point.y - pendingServerFileLinkClick.origin.y
      )
      if delta.x * delta.x + delta.y * delta.y > 16 {
        self.pendingServerFileLinkClick = nil
      }
    }

    private func activatePendingServerFileLink(at point: NSPoint) {
      cancelPendingServerFileLinkIfDragged(to: point)
      guard let pending = pendingServerFileLinkClick else { return }
      pendingServerFileLinkClick = nil
      guard let hit = linkHit(at: point), hit.isServerFile, hit.range == pending.range else {
        return
      }
      _ = activateServerFileLink(pending.value, at: pending.range.location)
    }

    @discardableResult
    func activateServerFileLink(_ value: Any, at index: Int? = nil) -> Bool {
      let isImage = index.map { textStorage?.streamMarkdownHasImage(at: $0) ?? false } ?? false
      return handleMarkdownLink(value, isImage: isImage, action: linkAction, in: self, at: index)
    }

    private var currentMouseLocation: NSPoint {
      guard let window else { return .zero }
      let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
      return convert(windowPoint, from: nil)
    }

    private func correctVisualLineEndSelection(at point: NSPoint) {
      guard selectedRange().length > 0,
        let anchor = mouseSelectionAnchor,
        let endpoint = logicalBoundaryOutsideVisualLine(at: point, anchor: anchor)
      else { return }

      let range =
        anchor <= endpoint
        ? NSRange(location: anchor, length: endpoint - anchor)
        : NSRange(location: endpoint, length: anchor - endpoint)
      guard range != selectedRange() else { return }
      setSelectedRange(
        range,
        affinity: anchor <= endpoint ? .downstream : .upstream,
        stillSelecting: NSEvent.pressedMouseButtons & 1 != 0
      )
    }

    private func finishMouseSelectionRepaint() {
      isTrackingMouseSelection = false
      guard let dirtyRange = selectionRepaintTracker.finish(current: selectedRange()) else {
        return
      }
      repaintRemovedSelection(dirtyRange)
    }

    private func repaintRemovedSelection(
      _ characterRange: NSRange,
      immediately: Bool = false
    ) {
      guard let layoutManager, let textContainer,
        characterRange.length > 0
      else { return }

      layoutManager.invalidateDisplay(forCharacterRange: characterRange)
      let glyphRange = layoutManager.glyphRange(
        forCharacterRange: characterRange, actualCharacterRange: nil
      )
      let origin = textContainerOrigin
      var dirtyRects: [NSRect] = []
      layoutManager.enumerateEnclosingRects(
        forGlyphRange: glyphRange,
        withinSelectedGlyphRange: glyphRange,
        in: textContainer
      ) { rect, _ in
        dirtyRects.append(
          rect.offsetBy(dx: origin.x, dy: origin.y)
            .insetBy(dx: -2, dy: -2)
        )
      }

      let displayDirtyRects: @MainActor @Sendable () -> Void = { [weak self] in
        guard let self else { return }
        for rect in dirtyRects {
          self.setNeedsDisplay(rect)
          self.layer?.setNeedsDisplay(rect)
        }
      }

      if immediately {
        displayDirtyRects()
        displayIfNeeded()
      } else {
        DispatchQueue.main.async(execute: displayDirtyRects)
      }
    }

    func logicalBoundaryOutsideVisualLine(at viewPoint: NSPoint, anchor: Int) -> Int? {
      guard let layoutManager, let textContainer,
        layoutManager.numberOfGlyphs > 0
      else { return nil }

      let origin = textContainerOrigin
      let point = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
      let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
      var lineGlyphRange = NSRange()
      let usedRect = layoutManager.lineFragmentUsedRect(
        forGlyphAt: min(glyph, layoutManager.numberOfGlyphs - 1),
        effectiveRange: &lineGlyphRange
      )
      guard point.y >= usedRect.minY, point.y <= usedRect.maxY else { return nil }
      let lineCharacters = layoutManager.characterRange(
        forGlyphRange: lineGlyphRange, actualGlyphRange: nil
      )
      let lineStart = lineCharacters.location
      let lineEnd = NSMaxRange(lineCharacters)
      guard anchor < lineStart || anchor > lineEnd else { return nil }

      if point.x > usedRect.maxX {
        return lineEnd
      }
      if point.x < usedRect.minX {
        return lineStart
      }
      return nil
    }
  }

  struct SelectionRepaintTracker {
    private var paintedRange: NSRange?
    private var currentRange = NSRange(location: 0, length: 0)

    mutating func begin(with range: NSRange) {
      currentRange = range
      paintedRange = range.length > 0 ? range : nil
    }

    mutating func record(_ range: NSRange) -> [NSRange] {
      let removedRanges = currentRange.removingIntersection(with: range)
      currentRange = range
      if range.length > 0 {
        paintedRange = paintedRange.map { NSUnionRange($0, range) } ?? range
      }
      return removedRanges
    }

    mutating func finish(current: NSRange) -> NSRange? {
      defer {
        paintedRange = nil
        currentRange = NSRange(location: 0, length: 0)
      }
      guard let paintedRange, paintedRange != current else { return nil }
      return paintedRange
    }
  }

  extension NSRange {
    fileprivate func removingIntersection(with other: NSRange) -> [NSRange] {
      guard length > 0 else { return [] }
      let intersection = NSIntersectionRange(self, other)
      guard intersection.length > 0 else { return [self] }

      var ranges: [NSRange] = []
      if location < intersection.location {
        ranges.append(NSRange(location: location, length: intersection.location - location))
      }
      let intersectionEnd = NSMaxRange(intersection)
      let rangeEnd = NSMaxRange(self)
      if intersectionEnd < rangeEnd {
        ranges.append(NSRange(location: intersectionEnd, length: rangeEnd - intersectionEnd))
      }
      return ranges
    }
  }

#endif
