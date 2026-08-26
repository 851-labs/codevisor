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

    init(
        timeline: StreamingTextAnimationTimeline,
        sourceID: String,
        pacingSourceID: String? = nil,
        documentSource: String,
        isStreaming: Bool,
        animatesInitialContent: Bool,
        reduceMotion: Bool
    ) {
        self.timeline = timeline
        self.sourceID = sourceID
        self.pacingSourceID = pacingSourceID ?? sourceID
        self.documentSource = documentSource
        self.isStreaming = isStreaming
        self.animatesInitialContent = animatesInitialContent
        self.reduceMotion = reduceMotion
    }
}

/// Stored on attributed ranges and consumed only by the platform layout
/// managers. NSObject identity keeps attributed-string copying cheap.
final class StreamingTextFadeMetadata: NSObject, NSCopying {
    var startTime: TimeInterval
    var characterCount: Int

    init(startTime: TimeInterval, characterCount: Int = 1) {
        self.startTime = startTime
        self.characterCount = max(1, characterCount)
    }

    func copy(with _: NSZone? = nil) -> Any {
        self
    }

    func opacity(at time: TimeInterval) -> CGFloat {
        let linearProgress = (time - startTime) / StreamingTextAnimationSpec.fadeDuration
        guard linearProgress > 0 else { return 0 }
        guard linearProgress < 1 else { return 1 }
        return CGFloat(StreamingTextFadeCurve.value(at: linearProgress))
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

        if sourceID != context.sourceID {
            reset(at: now)
            sourceID = context.sourceID
        }
        timeline = context.timeline

        let ranges = StreamingWordSegmenter.segments(in: base.string)
        let sourceIsAppendOnly = context.documentSource.hasPrefix(documentSource)
        let oldWords = words
        var nextWords: [Word] = []
        nextWords.reserveCapacity(ranges.count)

        if !context.animatesInitialContent {
            // Navigation/remount baseline: populate the same word ledger the
            // live path uses, but put every current word safely in the past.
            // When the mount switches to live mode, an unchanged prefix keeps
            // these starts and only later appended words receive fresh ones.
            context.timeline.discard(oldWords.map(\.fade), at: now)
            context.timeline.baselineSource(
                context.documentSource,
                sourceID: context.pacingSourceID
            )
            let settledStart = now - StreamingTextAnimationSpec.fadeDuration
            for range in ranges {
                nextWords.append(
                    Word(
                        text: range.text,
                        fade: StreamingTextFadeMetadata(startTime: settledStart)
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
            context.timeline.discard(oldWords.map(\.fade), at: now)
            context.timeline.baselineSource(
                context.documentSource,
                sourceID: context.pacingSourceID
            )
            let settledStart = now - StreamingTextAnimationSpec.fadeDuration
            for range in ranges {
                nextWords.append(
                    Word(
                        text: range.text,
                        fade: StreamingTextFadeMetadata(startTime: settledStart)
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

        let reusedCount = sourceIsAppendOnly ? min(oldWords.count, ranges.count) : 0
        for index in 0..<reusedCount {
            oldWords[index].fade.characterCount = max(1, ranges[index].range.length)
        }
        context.timeline.observeSource(
            context.documentSource,
            sourceID: context.pacingSourceID,
            at: now
        )

        if !sourceIsAppendOnly {
            context.timeline.discard(oldWords.map(\.fade), at: now)
        } else if reusedCount < oldWords.count {
            context.timeline.discard(
                Array(oldWords.dropFirst(reusedCount)).map(\.fade),
                at: now
            )
        }
        let scheduled = context.timeline.scheduleSegments(
            characterCounts: ranges.dropFirst(reusedCount).map(\.range.length),
            at: now
        )
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
            let end = word.fade.startTime + StreamingTextAnimationSpec.fadeDuration
            guard end > now else { continue }
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
        return unicodeSegments(in: text)
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
