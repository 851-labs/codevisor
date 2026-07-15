import AppKit
import SwiftUI

/// A non-editable TextKit 1 text view whose display and measurement paths use
/// the same layout configuration. Unlike SwiftUI's `.textSelection`, enabling
/// selection never swaps the renderer or changes the view's line metrics.
public struct SelectableTextView: NSViewRepresentable {
    fileprivate enum Content {
        case attributed(NSAttributedString)
        case plain(PlainTextModel)
    }

    private let content: Content
    private let fillsWidth: Bool

    public init(attributedText: NSAttributedString, fillsWidth: Bool = true) {
        content = .attributed(attributedText)
        self.fillsWidth = fillsWidth
    }

    public init(
        _ text: String,
        font: NSFont = .preferredFont(forTextStyle: .body),
        foregroundColor: NSColor = .labelColor,
        lineSpacing: CGFloat = 0,
        fillsWidth: Bool = false
    ) {
        content = .plain(
            PlainTextModel(
                text: text,
                font: font,
                foregroundColor: foregroundColor,
                lineSpacing: lineSpacing
            )
        )
        self.fillsWidth = fillsWidth
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> SelectableTextKitView {
        let view = SelectableTextKitView()
        view.setContent(context.coordinator.attributedText(for: content))
        return view
    }

    public func updateNSView(_ textView: SelectableTextKitView, context: Context) {
        textView.setContent(context.coordinator.attributedText(for: content))
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView _: SelectableTextKitView,
        context: Context
    ) -> CGSize? {
        let text = context.coordinator.attributedText(for: content)
        let concreteProposal = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width: CGFloat
        if fillsWidth, let concreteProposal {
            // The common Markdown path gets one layout at its real width.
            width = max(1, concreteProposal)
        } else {
            let naturalWidth = context.coordinator.measurer.naturalWidth(for: text)
            width = min(max(1, concreteProposal ?? naturalWidth), naturalWidth)
        }
        return CGSize(width: width, height: context.coordinator.measurer.height(for: text, width: width))
    }

    @MainActor
    public final class Coordinator {
        fileprivate let measurer = TextKitTextMeasurer()
        private var attributedInput: NSAttributedString?
        private var stableAttributedText: NSAttributedString?
        private var plainModel: PlainTextModel?
        private var plainText: NSAttributedString?

        fileprivate func attributedText(for content: Content) -> NSAttributedString {
            switch content {
            case let .attributed(text):
                if attributedInput === text, let stableAttributedText {
                    return stableAttributedText
                }
                if let stableAttributedText, stableAttributedText.isEqual(to: text) {
                    attributedInput = text
                    return stableAttributedText
                }
                attributedInput = text
                stableAttributedText = text
                return text
            case let .plain(model):
                if model == plainModel, let plainText { return plainText }
                let text = model.attributedText
                plainModel = model
                plainText = text
                return text
            }
        }
    }
}

private struct PlainTextModel: Equatable {
    let text: String
    let font: NSFont
    let foregroundColor: NSColor
    let lineSpacing: CGFloat

    var attributedText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: foregroundColor,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

/// Value attached to ranges whose background is painted as a rounded chip by
/// `RoundedBackgroundLayoutManager`.
final class TextKitRoundedBackground: NSObject, NSCopying {
    let color: NSColor
    let cornerRadius: CGFloat

    init(color: NSColor, cornerRadius: CGFloat) {
        self.color = color
        self.cornerRadius = cornerRadius
    }

    func copy(with _: NSZone? = nil) -> Any {
        self
    }
}

extension NSAttributedString.Key {
    static let streamMarkdownRoundedBackground = NSAttributedString.Key(
        "com.851labs.codevisor.streamMarkdownRoundedBackground"
    )
}

/// Paints inline-code backgrounds in the same TextKit layout that draws the
/// selectable glyphs. Drawing before `super` leaves the native selection
/// highlight on top of the chip.
private final class RoundedBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawRoundedBackgrounds(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawRoundedBackgrounds(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage, glyphsToShow.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(
            .streamMarkdownRoundedBackground,
            in: characters,
            options: []
        ) { value, characterRange, _ in
            guard let background = value as? TextKitRoundedBackground else { return }
            let glyphRange = self.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            let visibleGlyphs = NSIntersectionRange(glyphRange, glyphsToShow)
            guard visibleGlyphs.length > 0 else { return }

            self.enumerateLineFragments(forGlyphRange: visibleGlyphs) {
                _, _, textContainer, lineGlyphRange, _ in
                let fragmentGlyphs = NSIntersectionRange(visibleGlyphs, lineGlyphRange)
                guard fragmentGlyphs.length > 0 else { return }
                var rect = self.boundingRect(
                    forGlyphRange: fragmentGlyphs,
                    in: textContainer
                )
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                rect = rect.insetBy(dx: 0, dy: 0.5)
                background.color.setFill()
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: min(background.cornerRadius, rect.height / 2),
                    yRadius: min(background.cornerRadius, rect.height / 2)
                ).fill()
            }
        }
    }
}

/// The displayed selectable view. It owns an explicit TextKit 1 stack so the
/// selectable and unselected states always share one layout engine.
@MainActor
public final class SelectableTextKitView: TranscriptSelectableTextView {
    private var representedText: NSAttributedString?

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = RoundedBackgroundLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        focusRingType = .none
        allowsUndo = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ text: NSAttributedString) {
        guard representedText !== text else { return }
        if let representedText, representedText.isEqual(to: text) {
            self.representedText = text
            return
        }
        let selection = selectedRange()
        updateLinkHover(at: nil)
        representedText = text
        textStorage?.setAttributedString(text)
        let location = min(selection.location, text.length)
        let length = min(selection.length, text.length - location)
        setSelectedRange(NSRange(location: location, length: length))
        needsDisplay = true
    }

    /// Testable display-stack measurement. Selection is deliberately absent
    /// from this calculation; changing the selected range cannot alter glyph
    /// generation or the resulting height.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let width = max(1, width)
        setFrameSize(NSSize(width: width, height: max(1, frame.height)))
        guard let layoutManager, let textContainer else { return 1 }
        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        return max(1, ceil(layoutManager.usedRect(for: textContainer).height))
    }
}

/// Shared selection lifecycle for every read-only TextKit surface in the
/// transcript, including prose, code blocks, tables, diffs, and tool output.
///
/// AppKit normally preserves a non-empty selection after an `NSTextView`
/// resigns first responder and paints it with the inactive-selection color.
/// A transcript contains many independent text views, so that editor behavior
/// makes old selections appear to accumulate as the user clicks around.
@MainActor
public class TranscriptSelectableTextView: NSTextView {
    private var mouseSelectionAnchor: Int?
    private var selectionBeforeMouseDown: NSRange?
    private var linkHoverTrackingArea: NSTrackingArea?
    private(set) var hoveredLinkRange: NSRange?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkHoverTrackingArea {
            removeTrackingArea(linkHoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        linkHoverTrackingArea = area
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
        selectionBeforeMouseDown = selectedRange()
        if event.clickCount == 1,
            event.modifierFlags.intersection([.shift, .command, .option]).isEmpty
        {
            mouseSelectionAnchor = characterIndexForInsertion(
                at: convert(event.locationInWindow, from: nil)
            )
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
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        correctVisualLineEndSelection(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        correctVisualLineEndSelection(at: convert(event.locationInWindow, from: nil))
        finishMouseSelectionRepaint()
        mouseSelectionAnchor = nil
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
        guard textStorage.attribute(
            .link,
            at: characterIndex,
            effectiveRange: &effectiveRange
        ) != nil else { return nil }
        return effectiveRange
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

        let range = anchor <= endpoint
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
        defer { selectionBeforeMouseDown = nil }
        guard let previous = selectionBeforeMouseDown,
            previous.length > 0,
            previous != selectedRange()
        else { return }
        repaintRemovedSelection(previous)
    }

    /// TextKit invalidates the exact selection geometry when a range changes.
    /// In a transparent layer-backed text view, antialiased edge pixels can
    /// land just outside those rectangles and survive as one-pixel blue lines.
    /// Repaint only the old selection rects with a small margin, once after
    /// AppKit has finished updating its temporary selection attributes.
    private func repaintRemovedSelection(_ characterRange: NSRange) {
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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for rect in dirtyRects {
                self.setNeedsDisplay(rect)
                self.layer?.setNeedsDisplay(rect)
            }
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

/// Scratch TextKit stack used only for SwiftUI size probes. Probes never
/// resize or relayout the displayed `NSTextView`, so selection and scroll state
/// cannot be disturbed by measurement.
@MainActor
final class TextKitTextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = RoundedBackgroundLayoutManager()
    private let container = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private var measuredText: NSAttributedString?
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1
    private var naturalWidthText: NSAttributedString?
    private var cachedNaturalWidth: CGFloat = 1

    init() {
        storage.addLayoutManager(layoutManager)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
    }

    func height(for text: NSAttributedString, width: CGFloat) -> CGFloat {
        let width = max(1, width)
        if measuredText === text, abs(measuredWidth - width) <= 0.25 {
            return measuredHeight
        }
        if measuredText !== text {
            storage.setAttributedString(text)
            measuredText = text
        }
        container.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: container)
        measuredWidth = width
        measuredHeight = max(1, ceil(layoutManager.usedRect(for: container).height))
        return measuredHeight
    }

    func naturalWidth(for text: NSAttributedString) -> CGFloat {
        if naturalWidthText === text { return cachedNaturalWidth }
        if measuredText !== text {
            storage.setAttributedString(text)
            measuredText = text
        }
        container.containerSize = NSSize(
            width: 1_000_000,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: container)
        naturalWidthText = text
        cachedNaturalWidth = max(1, ceil(layoutManager.usedRect(for: container).width))
        // The next height query must lay out at its concrete wrapping width.
        measuredWidth = -1
        return cachedNaturalWidth
    }
}
