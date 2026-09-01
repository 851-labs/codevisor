import Foundation

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
