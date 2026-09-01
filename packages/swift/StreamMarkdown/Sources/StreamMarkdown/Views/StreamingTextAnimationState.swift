import Foundation
import QuartzCore

struct StreamingTextAnimationContext {
    let timeline: StreamingTextAnimationTimeline
    let sourceID: String
    /// Stable identity for the complete semantic stream whose arrival shape
    /// drives the shared presentation buffer. Nested native surfaces keep their
    /// own `sourceID` while reporting one source revision under this id.
    let pacingSourceID: String
    /// The whole message source, not just this block. Markdown can reclassify
    /// a growing tail (paragraph → list/table, incomplete emphasis → styled
    /// text) even though the provider stream itself remains append-only.
    let documentSource: String
    let isStreaming: Bool
    /// False for the first render of a semantic stream that predates the
    /// mounted transcript presentation. That render seeds the reconciler with
    /// already-visible words; subsequent appends use normal live animation.
    let animatesInitialContent: Bool
    let reduceMotion: Bool
    /// Invalidates native prepared-text caches after a suspended presentation
    /// resumes. The document itself may be unchanged, but every pending fade
    /// deadline has moved forward by the suspension duration.
    let playbackRevision: Int

    init(
        timeline: StreamingTextAnimationTimeline,
        sourceID: String,
        pacingSourceID: String? = nil,
        documentSource: String,
        isStreaming: Bool,
        animatesInitialContent: Bool,
        reduceMotion: Bool,
        playbackRevision: Int = 0
    ) {
        self.timeline = timeline
        self.sourceID = sourceID
        self.pacingSourceID = pacingSourceID ?? sourceID
        self.documentSource = documentSource
        self.isStreaming = isStreaming
        self.animatesInitialContent = animatesInitialContent
        self.reduceMotion = reduceMotion
        self.playbackRevision = playbackRevision
    }
}

/// Stored on attributed ranges and consumed only by the platform layout
/// managers. NSObject identity keeps attributed-string copying cheap.
enum StreamingTextRevealStyle: Equatable {
    case faded
    case atomic
}

final class StreamingTextFadeMetadata: NSObject, NSCopying {
    var startTime: TimeInterval
    var characterCount: Int
    let revealStyle: StreamingTextRevealStyle
    var minimumStartTime: TimeInterval?

    init(
        startTime: TimeInterval,
        characterCount: Int = 1,
        revealStyle: StreamingTextRevealStyle = .faded,
        minimumStartTime: TimeInterval? = nil
    ) {
        self.startTime = startTime
        self.characterCount = max(1, characterCount)
        self.revealStyle = revealStyle
        self.minimumStartTime = minimumStartTime
    }

    func copy(with _: NSZone? = nil) -> Any {
        self
    }

    func opacity(at time: TimeInterval) -> CGFloat {
        if revealStyle == .atomic {
            return time < startTime ? 0 : 1
        }
        let linearProgress = (time - startTime) / StreamingTextAnimationSpec.fadeDuration
        guard linearProgress > 0 else { return 0 }
        guard linearProgress < 1 else { return 1 }
        return CGFloat(StreamingTextFadeCurve.value(at: linearProgress))
    }

    var animationEndTime: TimeInterval {
        switch revealStyle {
        case .faded:
            startTime + StreamingTextAnimationSpec.fadeDuration
        case .atomic:
            startTime
        }
    }
}

extension NSAttributedString.Key {
    static let streamMarkdownFade = NSAttributedString.Key(
        "com.851labs.codevisor.streamMarkdownFade"
    )
}

struct PreparedStreamingText {
    let text: NSAttributedString
    let latestAnimationEnd: TimeInterval?
    let activeAnimationRanges: [NSRange]
}

/// Reconciles the rendered words owned by one native text surface. Existing
/// word slots retain their original start time while an append-only provider
/// stream grows, even if an incomplete Markdown construct changes how those
/// same source bytes are parsed or styled.
@MainActor
final class StreamingTextAnimationState {
    private struct Word {
        let text: String
        let fade: StreamingTextFadeMetadata

        var revealStyle: StreamingTextRevealStyle { fade.revealStyle }
    }

    private var sourceID: String?
    private var documentSource = ""
    private var words: [Word] = []
    private weak var timeline: StreamingTextAnimationTimeline?

    func prepare(
        _ base: NSAttributedString,
        context: StreamingTextAnimationContext?,
        now: TimeInterval = CACurrentMediaTime()
    ) -> PreparedStreamingText {
        guard let context, context.isStreaming else {
            reset(at: now)
            return PreparedStreamingText(
                text: base,
                latestAnimationEnd: nil,
                activeAnimationRanges: []
            )
        }

        let presentationNow = context.timeline.presentationTime(at: now)

        if sourceID != context.sourceID {
            reset(at: presentationNow)
            sourceID = context.sourceID
        }
        timeline = context.timeline

        let ranges = StreamingWordSegmenter.segments(in: base.string)
        // String.hasPrefix compares extended grapheme clusters. A provider
        // appending a skin tone or ZWJ component changes the trailing cluster,
        // even though its UTF-8 source bytes are still strictly append-only.
        let sourceIsAppendOnly = context.documentSource.utf8.starts(with: documentSource.utf8)
        let oldWords = words
        var nextWords: [Word] = []
        nextWords.reserveCapacity(ranges.count)

        if !context.animatesInitialContent {
            // Navigation/remount baseline: populate the same word ledger the
            // live path uses, but put every current word safely in the past.
            // When the mount switches to live mode, an unchanged prefix keeps
            // these starts and only later appended words receive fresh ones.
            context.timeline.discard(oldWords.map(\.fade), at: presentationNow)
            context.timeline.baselineSource(
                context.documentSource,
                sourceID: context.pacingSourceID
            )
            let settledStart = presentationNow - StreamingTextAnimationSpec.fadeDuration
            for range in ranges {
                nextWords.append(
                    Word(
                        text: range.text,
                        fade: StreamingTextFadeMetadata(
                            startTime: settledStart,
                            revealStyle: range.revealStyle
                        )
                    ))
            }
            documentSource = context.documentSource
            words = nextWords
            return PreparedStreamingText(
                text: base,
                latestAnimationEnd: nil,
                activeAnimationRanges: []
            )
        }

        if context.reduceMotion {
            // Existing and currently visible content becomes settled. If the
            // user turns Reduce Motion back off mid-response, only genuinely
            // new words animate.
            context.timeline.discard(oldWords.map(\.fade), at: presentationNow)
            context.timeline.baselineSource(
                context.documentSource,
                sourceID: context.pacingSourceID
            )
            let settledStart = presentationNow - StreamingTextAnimationSpec.fadeDuration
            for range in ranges {
                nextWords.append(
                    Word(
                        text: range.text,
                        fade: StreamingTextFadeMetadata(
                            startTime: settledStart,
                            revealStyle: range.revealStyle
                        )
                    ))
            }
            documentSource = context.documentSource
            words = nextWords
            return PreparedStreamingText(
                text: base,
                latestAnimationEnd: nil,
                activeAnimationRanges: []
            )
        }

        // Markdown structure can contract without the provider editing any
        // text. The common case is a completed image destination splitting one
        // live Markdown surface into prefix / preview / suffix. Reuse the
        // unchanged rendered word prefix across that structural boundary so
        // already-visible prose never receives a second entrance animation.
        // Append-only updates retain the existing positional rule because the
        // last rendered word may legitimately grow as more characters arrive.
        let candidateReuseCount = min(oldWords.count, ranges.count)
        var reusedCount = 0
        while reusedCount < candidateReuseCount {
            let oldWord = oldWords[reusedCount]
            let range = ranges[reusedCount]
            guard oldWord.revealStyle == range.revealStyle else { break }
            guard sourceIsAppendOnly || oldWord.text == range.text else { break }
            reusedCount += 1
        }
        for index in 0..<reusedCount {
            oldWords[index].fade.characterCount = max(1, ranges[index].range.length)
        }
        context.timeline.observeSource(
            context.documentSource,
            sourceID: context.pacingSourceID,
            at: presentationNow
        )

        if reusedCount < oldWords.count {
            context.timeline.discard(
                Array(oldWords.dropFirst(reusedCount)).map(\.fade),
                at: presentationNow
            )
        }
        let scheduled = context.timeline.scheduleSegments(
            characterCounts: ranges.dropFirst(reusedCount).map(\.range.length),
            revealStyles: ranges.dropFirst(reusedCount).map(\.revealStyle),
            at: presentationNow
        )
        for index in 0..<reusedCount
        where oldWords[index].revealStyle == .atomic
            && oldWords[index].text != ranges[index].text
        {
            context.timeline.restabilizeAtomicSegment(
                oldWords[index].fade,
                at: presentationNow
            )
        }
        var scheduledIndex = 0
        for (index, range) in ranges.enumerated() {
            let word: Word
            if index < reusedCount {
                // Position is the stable identity for an append-only rendered
                // block. This deliberately survives a growing final word and
                // Markdown tail reinterpretation.
                word = Word(text: range.text, fade: oldWords[index].fade)
            } else {
                word = Word(
                    text: range.text,
                    fade: scheduled[scheduledIndex]
                )
                scheduledIndex += 1
            }
            nextWords.append(word)
        }

        let output = NSMutableAttributedString(attributedString: base)
        var latestEnd: TimeInterval?
        var activeAnimationRanges: [NSRange] = []
        for (range, word) in zip(ranges, nextWords) {
            let end = word.fade.animationEndTime
            guard end > presentationNow else { continue }
            output.addAttribute(
                .streamMarkdownFade,
                value: word.fade,
                range: range.range
            )
            activeAnimationRanges.append(range.range)
            latestEnd = max(latestEnd ?? end, end)
        }

        documentSource = context.documentSource
        words = nextWords
        return PreparedStreamingText(
            text: output,
            latestAnimationEnd: latestEnd,
            activeAnimationRanges: activeAnimationRanges
        )
    }

    func reset(at now: TimeInterval = CACurrentMediaTime()) {
        timeline?.discard(words.map(\.fade), at: now)
        sourceID = nil
        documentSource = ""
        words = []
        timeline = nil
    }
}
