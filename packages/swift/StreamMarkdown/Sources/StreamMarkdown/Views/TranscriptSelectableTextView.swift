// The AppKit/TextKit rendering layer. iOS uses the matching UIKit/TextKit
// implementation in `SelectableTextView+UIKit.swift`.
#if canImport(AppKit)
    import AppKit
    import QuickLookUI
    import QuartzCore
    import SwiftUI

    @MainActor
    public class TranscriptSelectableTextView: NSTextView {
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
        private var pendingServerFileLinkClick: PendingServerFileLinkClick?
        private(set) var hoveredLinkRange: NSRange?
        var linkAction: MarkdownLinkAction?

        /// `NSTextView` normally claims the shared Quick Look panel so it can
        /// preview its own selected content. Transcript links are presented by
        /// the host's SwiftUI preview controller instead; declining here lets
        /// that controller remain the panel's data source after a link click
        /// makes this text view first responder.
        public override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
            false
        }

        public override func clicked(onLink link: Any, at charIndex: Int) {
            guard !handleMarkdownLink(link, action: linkAction) else { return }
            super.clicked(onLink: link, at: charIndex)
        }

        public override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // Install the hover tracking area ONLY when there is a link to hover.
            // AppKit calls this after every layout/scroll pass for every mounted
            // text view; unconditionally removing and re-adding an area forced a
            // structural tracking-region rebuild per view per scroll tick, and a
            // `.mouseMoved` area on link-free text ran a TextKit hit test at
            // pointer-move rate for nothing. The area uses `.inVisibleRect`, so
            // once installed it needs no per-layout refresh at all.
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

        /// Whether the current content has any `.link` run. Early-exits at the
        /// first link; link-free text (the vast majority of a transcript) costs
        /// one bounded attribute-run walk, far cheaper than the tracking-region
        /// rebuild it replaces.
        private var textStorageContainsLinks: Bool {
            guard let textStorage, textStorage.length > 0 else { return false }
            var found = false
            textStorage.enumerateAttributes(
                in: NSRange(location: 0, length: textStorage.length),
                options: [.longestEffectiveRangeNotRequired]
            ) { attributes, _, stop in
                if attributes[.link] != nil
                    || attributes[.streamMarkdownServerFileLink] != nil
                {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        public override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            updateLinkHover(at: convert(event.locationInWindow, from: nil))
        }

        public override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            updateLinkHover(at: convert(event.locationInWindow, from: nil))
        }

        public override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            updateLinkHover(at: nil)
        }

        public override func mouseDown(with event: NSEvent) {
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

            super.mouseDown(with: event)

            // NSTextView usually tracks the entire drag inside mouseDown. Keep the
            // mouseDragged/mouseUp overrides below as well for OS versions that
            // dispatch the tracking events through NSResponder instead.
            correctVisualLineEndSelection(at: currentMouseLocation)
            if NSEvent.pressedMouseButtons & 1 == 0 {
                finishMouseSelectionRepaint()
                mouseSelectionAnchor = nil
                activatePendingServerFileLink(at: currentMouseLocation)
            }
        }

        public override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            let point = convert(event.locationInWindow, from: nil)
            correctVisualLineEndSelection(at: point)
            cancelPendingServerFileLinkIfDragged(to: point)
        }

        public override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
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

            // NSTextView updates the selection repeatedly inside its mouse-down
            // tracking loop. Clean up each portion as soon as it leaves the live
            // selection; waiting for mouse-up makes the stale antialiased edge
            // pixels visible for the rest of the gesture.
            for range in removedRanges {
                repaintRemovedSelection(range, immediately: true)
            }
        }

        public override func resignFirstResponder() -> Bool {
            let didResign = super.resignFirstResponder()
            guard didResign else { return false }

            // Keep the selected text available for copying until focus actually
            // moves, then collapse the range to its trailing edge.
            let selection = selectedRange()
            if selection.length > 0 {
                setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
                repaintRemovedSelection(selection)
            }
            return true
        }

        /// Underlines only the link directly beneath the pointer. A temporary
        /// layout attribute keeps the source Markdown and its measured geometry
        /// unchanged while still repainting immediately as the pointer moves.
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

        private func linkHit(at viewPoint: NSPoint) -> LinkHit? {
            guard let layoutManager, let textContainer, let textStorage,
                textStorage.length > 0, layoutManager.numberOfGlyphs > 0
            else { return nil }

            let origin = textContainerOrigin
            let point = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
            let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
            guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

            // TextKit clamps points in surrounding whitespace to the nearest
            // glyph. Require the pointer to be inside the glyph's actual bounds so
            // a link does not remain underlined beyond its visible text.
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
            _ = activateServerFileLink(pending.value)
        }

        @discardableResult
        func activateServerFileLink(_ value: Any) -> Bool {
            handleMarkdownLink(value, action: linkAction)
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

        /// TextKit invalidates the exact selection geometry when a range changes.
        /// In a transparent layer-backed text view, antialiased edge pixels can
        /// land just outside those rectangles and survive as one-pixel blue lines.
        /// Repaint only the old selection rects with a small margin, once after
        /// AppKit has finished updating its temporary selection attributes.
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

        /// TextKit's drag tracker resolves points past the visual end of a line to
        /// its rightmost insertion point. In an LTR paragraph containing an RTL
        /// run, that point can be the RTL boundary in the middle of the logical
        /// string. `characterIndexForInsertion(at:)` does the right thing for a
        /// click, but multiline drag tracking does not. When the pointer is truly
        /// outside a different line from the anchor, use that line's logical
        /// boundary instead. Points inside the glyphs retain native bidi behavior.
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
            // `glyphIndex(for:in:)` clamps points above or below the text to the
            // nearest line. Never turn that clamped result into a selection jump.
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

    /// Tracks the full span painted by one mouse-selection gesture. The range can
    /// grow across the transcript and then shrink all the way back to its anchor,
    /// so comparing only the selection before and after mouseDown misses every
    /// rectangle that was selected in between.
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
        /// Returns the portions of this range that are not covered by `other`.
        /// Selection ranges are contiguous, so removing their intersection can
        /// yield at most one prefix and one suffix.
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
