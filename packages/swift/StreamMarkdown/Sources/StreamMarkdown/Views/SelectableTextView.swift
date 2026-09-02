// The AppKit/TextKit rendering layer. iOS uses the matching UIKit/TextKit
// implementation in `SelectableTextView+UIKit.swift`.
#if canImport(AppKit)
    import AppKit
    import QuickLookUI
    import QuartzCore
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
        private let streamingAnimation: StreamingTextAnimationContext?
        @Environment(\.streamingTextAnimationFrameClock) private var animationFrameClock
        @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth

        public init(attributedText: NSAttributedString, fillsWidth: Bool = true) {
            content = .attributed(attributedText)
            self.fillsWidth = fillsWidth
            streamingAnimation = nil
        }

        init(
            attributedText: NSAttributedString,
            fillsWidth: Bool = true,
            streamingAnimation: StreamingTextAnimationContext?
        ) {
            content = .attributed(attributedText)
            self.fillsWidth = fillsWidth
            self.streamingAnimation = streamingAnimation
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
            streamingAnimation = nil
        }

        public func makeNSView(context: Context) -> SelectableTextKitView {
            let view = SelectableTextKitView()
            view.animationFrameClock = animationFrameClock
            view.linkAction = context.environment.markdownLinkAction
            let prepared = context.coordinator.preparedText(
                for: content,
                animation: streamingAnimation
            )
            view.setContent(
                prepared.text,
                latestAnimationEnd: prepared.latestAnimationEnd,
                activeAnimationRanges: prepared.activeAnimationRanges
            )
            _ = view.contentHeight(
                forWidth: resolvedWidth(for: prepared.text, proposalWidth: nil, context: context)
            )
            return view
        }

        public func updateNSView(_ textView: SelectableTextKitView, context: Context) {
            textView.animationFrameClock = animationFrameClock
            textView.linkAction = context.environment.markdownLinkAction
            let prepared = context.coordinator.preparedText(
                for: content,
                animation: streamingAnimation
            )
            textView.setContent(
                prepared.text,
                latestAnimationEnd: prepared.latestAnimationEnd,
                activeAnimationRanges: prepared.activeAnimationRanges
            )
            _ = textView.contentHeight(
                forWidth: resolvedWidth(for: prepared.text, proposalWidth: nil, context: context)
            )
        }

        public func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: SelectableTextKitView,
            context: Context
        ) -> CGSize? {
            let prepared = context.coordinator.preparedText(
                for: content,
                animation: streamingAnimation
            )
            // A hosting-controller size probe can run before `updateNSView`
            // has applied this value's text. Measure the text this probe was
            // given, not whatever the view last displayed; `setContent` is a
            // no-op for an unchanged string.
            nsView.setContent(
                prepared.text,
                latestAnimationEnd: prepared.latestAnimationEnd,
                activeAnimationRanges: prepared.activeAnimationRanges
            )
            let width = resolvedWidth(
                for: prepared.text,
                proposalWidth: proposal.width,
                context: context
            )
            return CGSize(width: width, height: nsView.contentHeight(forWidth: width))
        }

        private func resolvedWidth(
            for text: NSAttributedString,
            proposalWidth: CGFloat?,
            context: Context
        ) -> CGFloat {
            StreamMarkdownTextLayout.resolvedWidth(
                proposalWidth: proposalWidth,
                rowLayoutWidth: rowLayoutWidth,
                fillsWidth: fillsWidth,
                naturalWidth: context.coordinator.measurer.naturalWidth(for: text)
            )
        }

        @MainActor
        public final class Coordinator: NSObject {
            fileprivate lazy var measurer = TextKitTextMeasurer()

            private let animationState = StreamingTextAnimationState()
            private var attributedInput: NSAttributedString?
            private var stableAttributedText: NSAttributedString?
            private var plainModel: PlainTextModel?
            private var plainText: NSAttributedString?
            private var preparedInput: NSAttributedString?
            private var preparedSourceID: String?
            private var preparedDocumentSource: String?
            private var preparedIsStreaming = false
            private var preparedAnimatesInitialContent = false
            private var preparedReduceMotion = false
            private var preparedPlaybackRevision = 0
            private var prepared: PreparedStreamingText?

            fileprivate func preparedText(
                for content: Content,
                animation: StreamingTextAnimationContext?
            ) -> PreparedStreamingText {
                let text = attributedText(for: content)
                if preparedInput === text,
                    preparedSourceID == animation?.sourceID,
                    preparedDocumentSource == animation?.documentSource,
                    preparedIsStreaming == (animation?.isStreaming ?? false),
                    preparedAnimatesInitialContent == (animation?.animatesInitialContent ?? false),
                    preparedReduceMotion == (animation?.reduceMotion ?? false),
                    preparedPlaybackRevision == (animation?.playbackRevision ?? 0),
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
                preparedPlaybackRevision = animation?.playbackRevision ?? 0
                prepared = value
                return value
            }

            private func attributedText(for content: Content) -> NSAttributedString {
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
                    let text = PlainTextRenderCache.shared.value(for: model)
                    plainModel = model
                    plainText = text
                    return text
                }
            }
        }
    }

#endif
