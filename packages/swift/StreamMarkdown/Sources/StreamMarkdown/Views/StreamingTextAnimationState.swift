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

struct StreamingWordSegment: Equatable {
    let range: NSRange
    let text: String
    let revealStyle: StreamingTextRevealStyle

    init(
        range: NSRange,
        text: String,
        revealStyle: StreamingTextRevealStyle = .faded
    ) {
        self.range = range
        self.text = text
        self.revealStyle = revealStyle
    }
}

/// Matches the desktop app's word-like segmentation contract:
///
/// - ASCII alphanumeric runs start segments.
/// - Punctuation and whitespace attach to the preceding segment.
/// - Non-ASCII strings use the platform Unicode word breaker, with every
///   non-word gap attached to the preceding word.
enum StreamingWordSegmenter {
    static func segments(in text: String) -> [StreamingWordSegment] {
        guard !text.isEmpty else { return [] }
        if text.unicodeScalars.allSatisfy({ $0.value <= 0x7f }) {
            return asciiSegments(in: text)
        }
        return splitEmojiClusters(in: text, segments: unicodeSegments(in: text))
    }

    private static func asciiSegments(in text: String) -> [StreamingWordSegment] {
        let units = Array(text.utf16)
        var ranges: [NSRange] = []
        var index = 0

        while index < units.count {
            if isASCIIWordUnit(units[index]) {
                let start = index
                repeat { index += 1 } while index < units.count && isASCIIWordUnit(units[index])
                ranges.append(NSRange(location: start, length: index - start))
            } else {
                if ranges.isEmpty {
                    ranges.append(NSRange(location: index, length: 1))
                } else {
                    ranges[ranges.count - 1].length += 1
                }
                index += 1
            }
        }

        let string = text as NSString
        return ranges.map { StreamingWordSegment(range: $0, text: string.substring(with: $0)) }
    }

    private static func unicodeSegments(in text: String) -> [StreamingWordSegment] {
        var wordRanges: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            wordRanges.append(range)
        }

        guard !wordRanges.isEmpty else {
            return [
                StreamingWordSegment(
                    range: NSRange(text.startIndex..<text.endIndex, in: text),
                    text: text
                )
            ]
        }

        var result: [StreamingWordSegment] = []
        var cursor = text.startIndex

        func appendGap(_ range: Range<String.Index>) {
            guard !range.isEmpty else { return }
            let gapRange = NSRange(range, in: text)
            if result.isEmpty {
                result.append(
                    StreamingWordSegment(
                        range: gapRange,
                        text: String(text[range])
                    )
                )
            } else {
                let previous = result.removeLast()
                let combined = NSRange(
                    location: previous.range.location,
                    length: NSMaxRange(gapRange) - previous.range.location
                )
                result.append(
                    StreamingWordSegment(
                        range: combined,
                        text: (text as NSString).substring(with: combined)
                    )
                )
            }
        }

        for range in wordRanges {
            appendGap(cursor..<range.lowerBound)
            result.append(
                StreamingWordSegment(
                    range: NSRange(range, in: text),
                    text: String(text[range])
                )
            )
            cursor = range.upperBound
        }
        appendGap(cursor..<text.endIndex)
        return result
    }

    private static func isASCIIWordUnit(_ unit: UInt16) -> Bool {
        (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
    }

    /// TextKit draws color emoji as indivisible glyphs, so keep every extended
    /// grapheme cluster containing emoji scalars in its own atomic segment.
    /// Punctuation and whitespace following an emoji stay attached to that
    /// segment, matching the word segmenter's existing attachment contract.
    private static func splitEmojiClusters(
        in text: String,
        segments: [StreamingWordSegment]
    ) -> [StreamingWordSegment] {
        var result: [StreamingWordSegment] = []

        for segment in segments {
            guard let swiftRange = Range(segment.range, in: text) else { continue }
            var cursor = swiftRange.lowerBound
            var atomicResultIndex: Int?
            var characterStart = swiftRange.lowerBound

            while characterStart < swiftRange.upperBound {
                let characterEnd = text.index(after: characterStart)
                let characterRange = characterStart..<characterEnd
                defer { characterStart = characterEnd }
                guard isEmoji(text[characterStart]) else { continue }
                if let atomicResultIndex {
                    let previous = result[atomicResultIndex]
                    let gap = NSRange(cursor..<characterRange.lowerBound, in: text)
                    let extended = NSRange(
                        location: previous.range.location,
                        length: NSMaxRange(gap)
                            - previous.range.location
                    )
                    result[atomicResultIndex] = StreamingWordSegment(
                        range: extended,
                        text: (text as NSString).substring(with: extended),
                        revealStyle: .atomic
                    )
                } else if cursor < characterRange.lowerBound {
                    let prefix = NSRange(cursor..<characterRange.lowerBound, in: text)
                    result.append(
                        StreamingWordSegment(
                            range: prefix,
                            text: (text as NSString).substring(with: prefix)
                        )
                    )
                }

                let emojiRange = NSRange(characterRange, in: text)
                result.append(
                    StreamingWordSegment(
                        range: emojiRange,
                        text: (text as NSString).substring(with: emojiRange),
                        revealStyle: .atomic
                    )
                )
                atomicResultIndex = result.count - 1
                cursor = characterRange.upperBound
            }

            if let atomicResultIndex {
                let previous = result[atomicResultIndex]
                let tail = NSRange(cursor..<swiftRange.upperBound, in: text)
                let extended = NSRange(
                    location: previous.range.location,
                    length: NSMaxRange(tail)
                        - previous.range.location
                )
                result[atomicResultIndex] = StreamingWordSegment(
                    range: extended,
                    text: (text as NSString).substring(with: extended),
                    revealStyle: .atomic
                )
            } else {
                result.append(segment)
            }
        }

        return result
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || scalar.value == 0xFE0F  // emoji variation selector
                || scalar.value == 0x20E3  // combining enclosing keycap
        }
    }
}

/// CSS cubic-bezier(.37, .55, .86, .88), evaluated as y for a supplied time
/// fraction x. Newton iteration handles the common case; bisection makes the
/// result deterministic near flat tangents.
enum StreamingTextFadeCurve {
    private static let x1 = StreamingTextAnimationSpec.fadeCurveX1
    private static let y1 = StreamingTextAnimationSpec.fadeCurveY1
    private static let x2 = StreamingTextAnimationSpec.fadeCurveX2
    private static let y2 = StreamingTextAnimationSpec.fadeCurveY2

    static func value(at progress: Double) -> Double {
        let progress = min(1, max(0, progress))
        var parameter = progress

        for _ in 0..<6 {
            let error = sample(parameter, first: x1, second: x2) - progress
            let slope = derivative(parameter, first: x1, second: x2)
            guard abs(slope) > 1e-7 else { break }
            parameter -= error / slope
            parameter = min(1, max(0, parameter))
        }

        var lower = 0.0
        var upper = 1.0
        for _ in 0..<12 {
            let sampled = sample(parameter, first: x1, second: x2)
            if abs(sampled - progress) < 1e-7 { break }
            if sampled < progress {
                lower = parameter
            } else {
                upper = parameter
            }
            parameter = (lower + upper) / 2
        }

        return sample(parameter, first: y1, second: y2)
    }

    private static func sample(_ value: Double, first: Double, second: Double) -> Double {
        let inverse = 1 - value
        return 3 * inverse * inverse * value * first
            + 3 * inverse * value * value * second
            + value * value * value
    }

    private static func derivative(_ value: Double, first: Double, second: Double) -> Double {
        let inverse = 1 - value
        return 3 * inverse * inverse * first
            + 6 * inverse * value * (second - first)
            + 3 * value * value * (1 - second)
    }
}
