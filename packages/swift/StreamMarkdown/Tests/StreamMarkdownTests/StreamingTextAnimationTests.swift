import Foundation
import Testing
@testable import StreamMarkdown

@MainActor
@Suite("Streaming text animation")
struct StreamingTextAnimationTests {
    @Test("ASCII segmentation keeps punctuation and whitespace with the preceding word")
    func asciiSegmentation() {
        let segments = StreamingWordSegmenter.segments(in: "Hello, world!  Next")
        #expect(segments.map(\.text) == ["Hello, ", "world!  ", "Next"])
        #expect(
            segments.map(\.range) == [
                NSRange(location: 0, length: 7),
                NSRange(location: 7, length: 8),
                NSRange(location: 15, length: 4),
            ])
    }

    @Test("Leading punctuation remains a segment and Unicode content is lossless")
    func unicodeSegmentation() {
        let text = "— hello 世界 👋🏽!"
        let segments = StreamingWordSegmenter.segments(in: text)
        let rebuilt = segments.map(\.text).joined()
        #expect(rebuilt == text)
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.range.length > 0 })
    }

    @Test("Normal cadence compresses after 96 milliseconds of queued delay")
    func cadence() {
        let timeline = StreamingTextAnimationTimeline()
        let now = 10.0
        let delays = (0..<9).map { _ in timeline.scheduleSegment(at: now) - now }
        let milliseconds = delays.map { Int(($0 * 1_000).rounded()) }
        #expect(milliseconds == [0, 16, 32, 48, 64, 80, 96, 100, 104])
    }

    @Test("An idle timeline starts the next segment immediately")
    func idleTimeline() {
        let timeline = StreamingTextAnimationTimeline()
        _ = timeline.scheduleSegment(at: 1)
        _ = timeline.scheduleSegment(at: 1)
        #expect(timeline.scheduleSegment(at: 5) == 5)
    }

    @Test("Timeline stays active through the final scheduled glyph fade")
    func activityLifetime() {
        let timeline = StreamingTextAnimationTimeline()
        let firstStart = timeline.scheduleSegment(at: 10)
        let secondStart = timeline.scheduleSegment(at: 10)

        #expect(timeline.isAnimationActive(at: firstStart))
        #expect(timeline.isAnimationActive(at: secondStart + 0.149))
        #expect(!timeline.isAnimationActive(at: secondStart + 0.150))

        timeline.reset()
        #expect(!timeline.isAnimationActive(at: 10))
    }

    @Test("Activity observer follows scheduling and reset")
    func activityObserver() async {
        let timeline = StreamingTextAnimationTimeline()
        var reports: [Bool] = []
        timeline.observeActivity { reports.append($0) }
        await Task.yield()
        #expect(reports == [false])

        _ = timeline.scheduleSegment(at: ProcessInfo.processInfo.systemUptime)
        await Task.yield()
        #expect(reports.last == true)

        timeline.reset()
        await Task.yield()
        #expect(reports.last == false)
    }

    @Test("Fade curve is bounded, monotonic, and reaches both endpoints")
    func fadeCurve() {
        #expect(StreamingTextFadeCurve.value(at: 0) == 0)
        #expect(StreamingTextFadeCurve.value(at: 1) == 1)
        let samples = stride(from: 0.0, through: 1.0, by: 0.05)
            .map(StreamingTextFadeCurve.value(at:))
        #expect(samples.allSatisfy { (0...1).contains($0) })
        #expect(zip(samples, samples.dropFirst()).allSatisfy(<=))
    }

    @Test("Append-only updates retain old starts and schedule only new words")
    func stableStarts() {
        let timeline = StreamingTextAnimationTimeline()
        let state = StreamingTextAnimationState()
        let firstContext = StreamingTextAnimationContext(
            timeline: timeline,
            sourceID: "paragraph-0",
            documentSource: "Hello",
            isStreaming: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        let first = state.prepare(
            NSAttributedString(string: "Hello"),
            context: firstContext,
            now: 1
        )
        let firstMetadata =
            first.text.attribute(
                .streamMarkdownFade,
                at: 0,
                effectiveRange: nil
            ) as? StreamingTextFadeMetadata
        #expect(firstMetadata?.startTime == 1)

        let secondContext = StreamingTextAnimationContext(
            timeline: timeline,
            sourceID: "paragraph-0",
            documentSource: "Hello world",
            isStreaming: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        let second = state.prepare(
            NSAttributedString(string: "Hello world"),
            context: secondContext,
            now: 1.02
        )
        let oldMetadata =
            second.text.attribute(
                .streamMarkdownFade,
                at: 0,
                effectiveRange: nil
            ) as? StreamingTextFadeMetadata
        let newMetadata =
            second.text.attribute(
                .streamMarkdownFade,
                at: 6,
                effectiveRange: nil
            ) as? StreamingTextFadeMetadata
        #expect(oldMetadata?.startTime == 1)
        #expect(newMetadata?.startTime == 1.02)
    }

    @Test("Reduce Motion and completion expose text immediately")
    func immediateVisibility() {
        let timeline = StreamingTextAnimationTimeline()
        let state = StreamingTextAnimationState()
        let reduced = state.prepare(
            NSAttributedString(string: "Immediately visible"),
            context: StreamingTextAnimationContext(
                timeline: timeline,
                sourceID: "paragraph-0",
                documentSource: "Immediately visible",
                isStreaming: true,
                animatesInitialContent: true,
                reduceMotion: true
            ),
            now: 1
        )
        #expect(reduced.latestAnimationEnd == nil)
        #expect(reduced.text.attribute(.streamMarkdownFade, at: 0, effectiveRange: nil) == nil)

        let complete = state.prepare(
            NSAttributedString(string: "Immediately visible"),
            context: StreamingTextAnimationContext(
                timeline: timeline,
                sourceID: "paragraph-0",
                documentSource: "Immediately visible",
                isStreaming: false,
                animatesInitialContent: true,
                reduceMotion: false
            ),
            now: 1
        )
        #expect(complete.latestAnimationEnd == nil)
        #expect(complete.text.attribute(.streamMarkdownFade, at: 0, effectiveRange: nil) == nil)
    }

    @Test("A navigation baseline settles existing words and later appends still animate")
    func navigationBaseline() {
        let timeline = StreamingTextAnimationTimeline()
        let state = StreamingTextAnimationState()
        let baseline = state.prepare(
            NSAttributedString(string: "Already here"),
            context: StreamingTextAnimationContext(
                timeline: timeline,
                sourceID: "paragraph-0",
                documentSource: "Already here",
                isStreaming: true,
                animatesInitialContent: false,
                reduceMotion: false
            ),
            now: 1
        )
        #expect(baseline.latestAnimationEnd == nil)
        #expect(baseline.text.attribute(.streamMarkdownFade, at: 0, effectiveRange: nil) == nil)

        let appended = state.prepare(
            NSAttributedString(string: "Already here now"),
            context: StreamingTextAnimationContext(
                timeline: timeline,
                sourceID: "paragraph-0",
                documentSource: "Already here now",
                isStreaming: true,
                animatesInitialContent: true,
                reduceMotion: false
            ),
            now: 1.02
        )
        #expect(appended.text.attribute(.streamMarkdownFade, at: 0, effectiveRange: nil) == nil)
        let newMetadata =
            appended.text.attribute(
                .streamMarkdownFade,
                at: 13,
                effectiveRange: nil
            ) as? StreamingTextFadeMetadata
        #expect(newMetadata?.startTime == 1.02)
    }

    @Test("Presentation claims animate only the first live mount of a new semantic stream")
    func presentationClaims() {
        let presentation = StreamingTextAnimationPresentation(
            settledStreamIDs: ["existing"]
        )
        #expect(!presentation.claimInitialAnimation(for: "existing"))
        #expect(presentation.claimInitialAnimation(for: "new"))
        #expect(!presentation.claimInitialAnimation(for: "new"))
    }

    @Test("Presentation establishes its navigation baseline only once")
    func presentationBaseline() {
        let presentation = StreamingTextAnimationPresentation()
        var buildCount = 0
        presentation.establishBaseline {
            buildCount += 1
            return ["existing"]
        }
        presentation.establishBaseline {
            buildCount += 1
            return ["later"]
        }

        #expect(buildCount == 1)
        #expect(!presentation.claimInitialAnimation(for: "existing"))
        #expect(presentation.claimInitialAnimation(for: "later"))
    }

    @Test("Structural blocks reveal in document order between animated text runs")
    func structuralBlockSequence() {
        let sequence = StreamingMarkdownBlockEntranceSequence()
        let segments: [MarkdownSegment] = [
            .textRun([.paragraph("Before")]),
            .block(.codeBlock(language: "swift", code: "let x = 1", isComplete: true)),
            .textRun([.paragraph("Between")]),
            .block(
                .table(
                    headers: ["Name"],
                    alignments: [.leading],
                    rows: [["Ada"]]
                )),
            .textRun([.paragraph("After")]),
        ]

        var resolution = sequence.resolve(
            segments: segments,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 1)
        let codeID = try! #require(resolution.pendingBlockID)

        #expect(sequence.beginReveal(blockID: codeID) == .started)
        resolution = sequence.resolve(
            segments: segments,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 2)
        #expect(resolution.revealingSegmentIndex == 1)

        #expect(sequence.finishReveal(blockID: codeID))
        resolution = sequence.resolve(
            segments: segments,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 3)
        let tableID = try! #require(resolution.pendingBlockID)
        #expect(tableID != codeID)

        #expect(sequence.beginReveal(blockID: tableID) == .started)
        #expect(sequence.finishReveal(blockID: tableID))
        resolution = sequence.resolve(
            segments: segments,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == segments.count)
        #expect(resolution.pendingBlockID == nil)
    }

    @Test("Navigation and Reduce Motion settle structural blocks immediately")
    func settledStructuralBlocks() {
        let sequence = StreamingMarkdownBlockEntranceSequence()
        let existing: [MarkdownSegment] = [
            .textRun([.paragraph("Before")]),
            .block(.codeBlock(language: nil, code: "old", isComplete: false)),
        ]

        var resolution = sequence.resolve(
            segments: existing,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: false,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == existing.count)
        #expect(resolution.pendingBlockID == nil)

        let appended =
            existing + [
                .textRun([.paragraph("Later")]),
                .block(.table(headers: ["A"], alignments: [.none], rows: [["1"]])),
            ]
        resolution = sequence.resolve(
            segments: appended,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 3)
        #expect(resolution.pendingBlockID != nil)

        resolution = sequence.resolve(
            segments: appended,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: true
        )
        #expect(resolution.visibleSegmentCount == appended.count)
        #expect(resolution.pendingBlockID == nil)
    }

    @Test("Growing a structural block keeps one entrance identity")
    func stableStructuralBlockIdentity() {
        let sequence = StreamingMarkdownBlockEntranceSequence()
        let first: [MarkdownSegment] = [
            .block(.codeBlock(language: "swift", code: "let", isComplete: false))
        ]
        var resolution = sequence.resolve(
            segments: first,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        let blockID = try! #require(resolution.pendingBlockID)
        #expect(sequence.beginReveal(blockID: blockID) == .started)
        #expect(sequence.beginReveal(blockID: blockID) == .resumed)
        #expect(sequence.finishReveal(blockID: blockID))

        let grown: [MarkdownSegment] = [
            .block(
                .codeBlock(
                    language: "swift",
                    code: "let value = 1",
                    isComplete: true
                ))
        ]
        resolution = sequence.resolve(
            segments: grown,
            animationPath: "stream.answer.root",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == grown.count)
        #expect(resolution.pendingBlockID == nil)
    }
}
