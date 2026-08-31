#if canImport(UIKit) && !canImport(AppKit)
    import QuartzCore
    import SwiftUI
    import UIKit

    /// A read-only UIKit/TextKit surface whose storage contains the complete text
    /// immediately. Streaming changes only glyph paint opacity, so wrapping,
    /// selection, copying, accessibility, and transcript scrolling stay stable.
    public struct SelectableTextView: UIViewRepresentable {
        private let attributedText: NSAttributedString
        private let fillsWidth: Bool
        private let streamingAnimation: StreamingTextAnimationContext?
        @Environment(\.markdownLinkAction) private var linkAction
        @Environment(\.streamingTextAnimationFrameClock) private var animationFrameClock

        public init(attributedText: NSAttributedString, fillsWidth: Bool = true) {
            self.attributedText = attributedText
            self.fillsWidth = fillsWidth
            streamingAnimation = nil
        }

        init(
            attributedText: NSAttributedString,
            fillsWidth: Bool = true,
            streamingAnimation: StreamingTextAnimationContext?
        ) {
            self.attributedText = attributedText
            self.fillsWidth = fillsWidth
            self.streamingAnimation = streamingAnimation
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        public func makeUIView(context: Context) -> SelectableTextKitView {
            let view = SelectableTextKitView()
            view.animationFrameClock = animationFrameClock
            context.coordinator.linkAction = linkAction
            view.delegate = context.coordinator
            let prepared = context.coordinator.preparedText(
                for: attributedText,
                animation: streamingAnimation
            )
            view.setContent(
                prepared.text,
                latestAnimationEnd: prepared.latestAnimationEnd,
                activeAnimationRanges: prepared.activeAnimationRanges
            )
            return view
        }

        public func updateUIView(_ textView: SelectableTextKitView, context: Context) {
            textView.animationFrameClock = animationFrameClock
            context.coordinator.linkAction = linkAction
            let prepared = context.coordinator.preparedText(
                for: attributedText,
                animation: streamingAnimation
            )
            textView.setContent(
                prepared.text,
                latestAnimationEnd: prepared.latestAnimationEnd,
                activeAnimationRanges: prepared.activeAnimationRanges
            )
        }

        public func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: SelectableTextKitView,
            context: Context
        ) -> CGSize? {
            let text = context.coordinator.preparedText(
                for: attributedText,
                animation: streamingAnimation
            ).text
            let concreteProposal = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            let width: CGFloat
            if fillsWidth, let concreteProposal {
                width = max(1, concreteProposal)
            } else {
                let naturalWidth = context.coordinator.measurer.naturalWidth(for: text)
                width = min(max(1, concreteProposal ?? naturalWidth), naturalWidth)
            }
            return CGSize(
                width: width,
                height: uiView.contentHeight(forWidth: width)
            )
        }

        @MainActor
        public final class Coordinator: NSObject, UITextViewDelegate {
            fileprivate lazy var measurer = UIKitTextKitTextMeasurer()
            fileprivate var linkAction: MarkdownLinkAction?
            private let animationState = StreamingTextAnimationState()
            private var attributedInput: NSAttributedString?
            private var stableAttributedText: NSAttributedString?
            private var preparedInput: NSAttributedString?
            private var preparedSourceID: String?
            private var preparedDocumentSource: String?
            private var preparedIsStreaming = false
            private var preparedAnimatesInitialContent = false
            private var preparedReduceMotion = false
            private var prepared: PreparedStreamingText?

            fileprivate func preparedText(
                for input: NSAttributedString,
                animation: StreamingTextAnimationContext?
            ) -> PreparedStreamingText {
                let text: NSAttributedString
                if attributedInput === input, let stableAttributedText {
                    text = stableAttributedText
                } else if let stableAttributedText, stableAttributedText.isEqual(to: input) {
                    attributedInput = input
                    text = stableAttributedText
                } else {
                    attributedInput = input
                    stableAttributedText = input
                    text = input
                }

                if preparedInput === text,
                    preparedSourceID == animation?.sourceID,
                    preparedDocumentSource == animation?.documentSource,
                    preparedIsStreaming == (animation?.isStreaming ?? false),
                    preparedAnimatesInitialContent == (animation?.animatesInitialContent ?? false),
                    preparedReduceMotion == (animation?.reduceMotion ?? false),
                    let prepared
                {
                    return prepared
                }

                let value = animationState.prepare(text, context: animation)
                preparedInput = text
                preparedSourceID = animation?.sourceID
                preparedDocumentSource = animation?.documentSource
                preparedIsStreaming = animation?.isStreaming ?? false
                preparedAnimatesInitialContent = animation?.animatesInitialContent ?? false
                preparedReduceMotion = animation?.reduceMotion ?? false
                prepared = value
                return value
            }

            public func textView(
                _: UITextView,
                primaryActionFor textItem: UITextItem,
                defaultAction: UIAction
            ) -> UIAction? {
                guard case let .link(url) = textItem.content, let linkAction else {
                    return defaultAction
                }
                return linkAction(url) ? UIAction { _ in } : defaultAction
            }
        }
    }

    /// Value attached to inline-code ranges. The layout manager paints the chip
    /// in the same pass as the selectable glyphs.
    final class UIKitTextKitRoundedBackground: NSObject, NSCopying {
        let color: UIColor
        let cornerRadius: CGFloat

        init(color: UIColor, cornerRadius: CGFloat) {
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

    private final class UIKitStreamingTextLayoutManager: NSLayoutManager {
        var animationTime = CACurrentMediaTime()

        override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
            drawRoundedBackgrounds(forGlyphRange: glyphsToShow, at: origin)
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        }

        override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
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
                let graphics = UIGraphicsGetCurrentContext()
                graphics?.saveGState()
                graphics?.setAlpha(opacity)
                super.drawGlyphs(forGlyphRange: visibleGlyphs, at: origin)
                graphics?.restoreGState()
            }

            if !drewRange {
                super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            }
        }

        private func drawRoundedBackgrounds(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
            guard let textStorage, glyphsToShow.length > 0 else { return }
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            textStorage.enumerateAttribute(
                .streamMarkdownRoundedBackground,
                in: characters
            ) { value, characterRange, _ in
                guard let background = value as? UIKitTextKitRoundedBackground else { return }
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
                    let graphics = UIGraphicsGetCurrentContext()
                    graphics?.saveGState()
                    graphics?.setAlpha(opacity)
                    background.color.setFill()
                    UIBezierPath(
                        roundedRect: rect,
                        cornerRadius: min(background.cornerRadius, rect.height / 2)
                    ).fill()
                    graphics?.restoreGState()
                }
            }
        }
    }

    @MainActor
    public final class SelectableTextKitView: UITextView, StreamingTextAnimationFrameClient {
        private var representedText: NSAttributedString?
        private var measuredWidth: CGFloat = -1
        private var measuredHeight: CGFloat = 1
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
            let layoutManager = UIKitStreamingTextLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let textContainer = NSTextContainer(
                size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            )
            textContainer.lineFragmentPadding = 0
            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = false
            layoutManager.addTextContainer(textContainer)

            super.init(frame: .zero, textContainer: textContainer)
            isEditable = false
            isSelectable = true
            isScrollEnabled = false
            isOpaque = false
            backgroundColor = .clear
            textContainerInset = .zero
            adjustsFontForContentSizeCategory = true
            dataDetectorTypes = []
            linkTextAttributes = [.foregroundColor: UIColor.link]
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
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

            let selection = selectedRange
            let previousText = representedText
            representedText = text
            measuredWidth = -1
            if let previousText,
                text.length >= previousText.length,
                text.string.hasPrefix(previousText.string),
                previousText.isEqual(
                    to: text.attributedSubstring(
                        from: NSRange(location: 0, length: previousText.length)
                    ))
            {
                textStorage.append(
                    text.attributedSubstring(
                        from: NSRange(
                            location: previousText.length,
                            length: text.length - previousText.length
                        ))
                )
            } else {
                textStorage.setAttributedString(text)
            }
            let location = min(selection.location, text.length)
            let length = min(selection.length, text.length - location)
            selectedRange = NSRange(location: location, length: length)
            setNeedsDisplay()
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
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
            let link = CADisplayLink(target: self, selector: #selector(animationFrame(_:)))
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

        private var streamingLayoutManager: UIKitStreamingTextLayoutManager? {
            layoutManager as? UIKitStreamingTextLayoutManager
        }

        private func redrawActiveStreamingText(at time: TimeInterval) {
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
                rect.origin.x += textContainerInset.left
                rect.origin.y += textContainerInset.top
                setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
            }
        }

        func contentHeight(forWidth width: CGFloat) -> CGFloat {
            let width = max(1, width)
            if abs(measuredWidth - width) <= 0.25 {
                return measuredHeight
            }
            if abs(bounds.width - width) > 0.25 {
                bounds.size.width = width
            }
            textContainer.size = CGSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            measuredWidth = width
            measuredHeight = max(1, ceil(layoutManager.usedRect(for: textContainer).height))
            return measuredHeight
        }
    }

    @MainActor
    final class UIKitTextKitTextMeasurer {
        private let storage = NSTextStorage()
        private let layoutManager = UIKitStreamingTextLayoutManager()
        private let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        private var measuredText: NSAttributedString?
        private var naturalWidthText: NSAttributedString?
        private var cachedNaturalWidth: CGFloat = 1

        init() {
            storage.addLayoutManager(layoutManager)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)
        }

        func naturalWidth(for text: NSAttributedString) -> CGFloat {
            if naturalWidthText === text { return cachedNaturalWidth }
            if measuredText !== text {
                storage.setAttributedString(text)
                measuredText = text
            }
            container.size = CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            naturalWidthText = text
            cachedNaturalWidth = max(1, ceil(layoutManager.usedRect(for: container).width))
            return cachedNaturalWidth
        }
    }
#endif
