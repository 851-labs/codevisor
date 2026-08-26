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

    @Test("Character backlog accelerates early reveals and preserves the thin tail")
    func characterBacklogControlsCadence() {
        let timeline = StreamingTextAnimationTimeline()
        let now = 10.0
        timeline.observeSource(String(repeating: "a", count: 45), sourceID: "answer", at: now)
        let fades = timeline.scheduleSegments(
            characterCounts: Array(repeating: 5, count: 9),
            at: now
        )
        let intervals = zip(fades, fades.dropFirst()).map { $1.startTime - $0.startTime }
        let firstInterval = try! #require(intervals.first)
        let lastInterval = try! #require(intervals.last)

        #expect((0.020...0.100).contains(fades[0].startTime - now))
        #expect(firstInterval < lastInterval)
        #expect(
            intervals.allSatisfy {
                $0 >= StreamingTextAnimationSpec.fastestSegmentDelay
                    && $0 <= StreamingTextAnimationSpec.maximumSlowestSegmentDelay
            })
    }

    @Test("Observed stream shape adapts without a harness or model hint")
    func sourceShapeControlsTargetReserve() {
        let fine = StreamingTextAnimationTimeline()
        fine.observeSource("a", sourceID: "answer", at: 1.000)
        fine.observeSource("ab", sourceID: "answer", at: 1.020)
        fine.observeSource("abc", sourceID: "answer", at: 1.041)

        let bursty = StreamingTextAnimationTimeline()
        bursty.observeSource(String(repeating: "a", count: 40), sourceID: "answer", at: 1.000)
        bursty.observeSource(String(repeating: "a", count: 80), sourceID: "answer", at: 1.280)
        bursty.observeSource(String(repeating: "a", count: 120), sourceID: "answer", at: 1.620)

        #expect(fine.targetQueueLead < 0.080)
        #expect(bursty.targetQueueLead > 0.240)
        #expect(bursty.targetQueueLead <= StreamingTextAnimationSpec.maximumTargetQueueLead)
    }

    @Test("Duplicate renderer passes do not become source arrival samples")
    func duplicateSourceRevisionIsIgnored() {
        let timeline = StreamingTextAnimationTimeline()
        timeline.observeSource("Hello", sourceID: "answer", at: 1.000)
        timeline.observeSource("Hello", sourceID: "answer", at: 1.500)
        timeline.observeSource("Hello world", sourceID: "answer", at: 1.600)

        // The measured source gap is 600ms. If the duplicate render at 500ms
        // were sampled, this would instead look like a low-latency 100ms feed.
        #expect(timeline.targetQueueLead > 0.180)
    }

    @Test("A restored source baseline is not an arrival sample")
    func restoredSourceDoesNotTeachArrivalGap() {
        let timeline = StreamingTextAnimationTimeline()
        timeline.baselineSource("Already visible", sourceID: "answer")
        timeline.observeSource("Already visible now", sourceID: "answer", at: 20)

        #expect(timeline.targetQueueLead < 0.080)
    }

    @Test("A following source update refills the reserve without moving a started word")
    func followingChunkRefillsReserve() {
        let timeline = StreamingTextAnimationTimeline()
        timeline.observeSource("Hello world", sourceID: "answer", at: 10)
        let first = timeline.scheduleSegments(characterCounts: [6, 5], at: 10)

        let started = first[0].startTime
        timeline.observeSource("Hello world again", sourceID: "answer", at: 10.030)
        let additions = timeline.scheduleSegments(characterCounts: [6], at: 10.030)

        #expect(first[0].startTime == started)
        #expect(first[1].startTime >= 10.030)
        #expect(try! #require(additions.first).startTime > first[1].startTime)
    }

    @Test("An idle timeline rebuilds its short presentation reserve")
    func idleTimelineRebuffers() {
        let timeline = StreamingTextAnimationTimeline()
        timeline.observeSource("one", sourceID: "answer", at: 1)
        _ = timeline.scheduleSegments(characterCounts: [3], at: 1)
        timeline.observeSource("one two", sourceID: "answer", at: 5)
        let next = timeline.scheduleSegments(characterCounts: [4], at: 5)
        let lead = try! #require(next.first).startTime - 5
        #expect((0.019...0.101).contains(lead))
    }

    @Test("Timeline stays active through the final scheduled glyph fade")
    func activityLifetime() {
        let timeline = StreamingTextAnimationTimeline()
        let fades = timeline.scheduleSegments(characterCounts: [4, 4], at: 10)
        let firstStart = fades[0].startTime
        let secondStart = fades[1].startTime

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

        _ = timeline.scheduleSegments(
            characterCounts: [4],
            at: ProcessInfo.processInfo.systemUptime
        )
        await Task.yield()
        #expect(reports.last == true)

        timeline.reset()
        await Task.yield()
        #expect(reports.last == false)
    }

    @Test("Response completion waits for pending structural entrances")
    func responseCompletionBarrier() async throws {
        let coordinator = StreamingContentAnimationCoordinator()
        coordinator.setPendingEntrance(true, sourceID: "answer.0")
        var finished = false
        let waiter = Task { @MainActor in
            try await coordinator.waitUntilFullyIdle()
            finished = true
        }

        for _ in 0..<5 { await Task.yield() }
        #expect(!finished)

        coordinator.setPendingEntrance(false, sourceID: "answer.0")
        try await waiter.value
        #expect(finished)
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
        #expect(abs((firstMetadata?.startTime ?? 0) - 1.020) < 0.000_001)

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
        #expect(abs((oldMetadata?.startTime ?? 0) - 1.020) < 0.000_001)
        #expect(abs((newMetadata?.startTime ?? 0) - 1.028) < 0.000_001)
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
        #expect((1.040...1.050).contains(newMetadata?.startTime ?? 0))
    }
}
