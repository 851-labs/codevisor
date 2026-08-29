// The AppKit/TextKit rendering layer. iOS uses the matching UIKit/TextKit
// implementation in `SelectableTextView+UIKit.swift`.
#if canImport(AppKit)
    import AppKit
    import QuickLookUI
    import QuartzCore
    import SwiftUI

    struct PlainTextModel: Equatable {
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
    final class StreamingTextLayoutManager: NSLayoutManager {
        var animationTime = CACurrentMediaTime()

        override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
            drawRoundedBackgrounds(forGlyphRange: glyphsToShow, at: origin)
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        }

        override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
            guard let textStorage, glyphsToShow.length > 0 else {
                super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
                return
            }

            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            var drewRange = false
            textStorage.enumerateAttribute(
                .streamMarkdownFade,
                in: characters,
                options: [.longestEffectiveRangeNotRequired]
            ) { value, characterRange, _ in
                let glyphRange = self.glyphRange(
                    forCharacterRange: characterRange,
                    actualCharacterRange: nil
                )
                let visibleGlyphs = NSIntersectionRange(glyphRange, glyphsToShow)
                guard visibleGlyphs.length > 0 else { return }
                drewRange = true

                let opacity =
                    (value as? StreamingTextFadeMetadata)?
                    .opacity(at: self.animationTime) ?? 1
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(opacity)
                super.drawGlyphs(forGlyphRange: visibleGlyphs, at: origin)
                NSGraphicsContext.restoreGraphicsState()
            }

            if !drewRange {
                super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            }
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
                    let opacity =
                        (textStorage.attribute(
                            .streamMarkdownFade,
                            at: characterRange.location,
                            effectiveRange: nil
                        ) as? StreamingTextFadeMetadata)?.opacity(at: self.animationTime) ?? 1
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current?.cgContext.setAlpha(opacity)
                    background.color.setFill()
                    NSBezierPath(
                        roundedRect: rect,
                        xRadius: min(background.cornerRadius, rect.height / 2),
                        yRadius: min(background.cornerRadius, rect.height / 2)
                    ).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
    }

    /// The displayed selectable view. It owns an explicit TextKit 1 stack so the
    /// selectable and unselected states always share one layout engine.
    @MainActor
    public final class SelectableTextKitView: TranscriptSelectableTextView,
        StreamingTextAnimationFrameClient
    {
        private var representedText: NSAttributedString?
        private var latestAnimationEnd: TimeInterval?
        private var activeAnimationRanges: [NSRange] = []
        private var animationDisplayLink: CADisplayLink?
        public var animationFrameClock: StreamingTextAnimationFrameClock? {
            didSet {
                guard animationFrameClock !== oldValue else { return }
                oldValue?.remove(self)
                stopAnimation()
                updateAnimation(until: latestAnimationEnd)
            }
        }

        init() {
            let textStorage = NSTextStorage()
            let layoutManager = StreamingTextLayoutManager()
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

        func setContent(
            _ text: NSAttributedString,
            latestAnimationEnd: TimeInterval? = nil,
            activeAnimationRanges: [NSRange] = []
        ) {
            self.activeAnimationRanges = activeAnimationRanges
            updateAnimation(until: latestAnimationEnd)
            guard representedText !== text else {
                redrawActiveStreamingText(at: CACurrentMediaTime())
                return
            }
            if let representedText, representedText.isEqual(to: text) {
                self.representedText = text
                redrawActiveStreamingText(at: CACurrentMediaTime())
                return
            }
            let selection = selectedRange()
            updateLinkHover(at: nil)
            let previousText = representedText
            representedText = text
            if let previousText,
                text.length >= previousText.length,
                text.string.hasPrefix(previousText.string),
                previousText.isEqual(
                    to: text.attributedSubstring(
                        from: NSRange(location: 0, length: previousText.length)
                    ))
            {
                textStorage?.append(
                    text.attributedSubstring(
                        from: NSRange(
                            location: previousText.length,
                            length: text.length - previousText.length
                        ))
                )
            } else {
                textStorage?.setAttributedString(text)
            }
            let location = min(selection.location, text.length)
            let length = min(selection.length, text.length - location)
            setSelectedRange(NSRange(location: location, length: length))
            needsDisplay = true
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopAnimation()
            } else {
                updateAnimation(until: latestAnimationEnd)
            }
        }

        private func updateAnimation(until endTime: TimeInterval?) {
            latestAnimationEnd = endTime
            let now = CACurrentMediaTime()
            streamingLayoutManager?.animationTime = now
            if let animationFrameClock {
                stopAnimation()
                animationFrameClock.update(self, until: endTime)
                return
            }
            guard let endTime, endTime > now else {
                stopAnimation()
                return
            }
            guard window != nil, animationDisplayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(animationFrame(_:)))
            link.add(to: .main, forMode: .common)
            animationDisplayLink = link
        }

        @objc private func animationFrame(_ displayLink: CADisplayLink) {
            streamingTextAnimationFrame(at: displayLink.timestamp)
            if let latestAnimationEnd, displayLink.timestamp >= latestAnimationEnd {
                stopAnimation()
            }
        }

        public func streamingTextAnimationFrame(at timestamp: TimeInterval) {
            streamingLayoutManager?.animationTime = timestamp
            redrawActiveStreamingText(at: timestamp)
        }

        private func stopAnimation() {
            animationDisplayLink?.invalidate()
            animationDisplayLink = nil
        }

        private var streamingLayoutManager: StreamingTextLayoutManager? {
            layoutManager as? StreamingTextLayoutManager
        }

        private func redrawActiveStreamingText(at time: TimeInterval) {
            guard let textStorage, let layoutManager, let textContainer else { return }
            for range in activeAnimationRanges where NSMaxRange(range) <= textStorage.length {
                guard
                    let fade = textStorage.attribute(
                        .streamMarkdownFade,
                        at: range.location,
                        effectiveRange: nil
                    ) as? StreamingTextFadeMetadata,
                    fade.startTime + StreamingTextAnimationSpec.fadeDuration > time
                else { continue }
                layoutManager.invalidateDisplay(forCharacterRange: range)
                let glyphs = layoutManager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                rect.origin.x += textContainerOrigin.x
                rect.origin.y += textContainerOrigin.y
                setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
            }
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

#endif
