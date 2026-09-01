import Foundation
import Testing
@testable import StreamMarkdown

@MainActor
@Suite("Streaming text presentation")
struct StreamingTextAnimationPresentationTests {
    @Test("Presentation claims animate only the first live mount of a new semantic stream")
    func presentationClaims() {
        let presentation = StreamingTextAnimationPresentation(
            settledStreamIDs: ["existing"]
        )
        #expect(!presentation.claimInitialAnimation(for: "existing"))
        #expect(presentation.claimInitialAnimation(for: "new"))
        #expect(!presentation.claimInitialAnimation(for: "new"))
    }

    @Test("Projection arrival decides first-mount animation before virtualization")
    func projectionArrivalPolicy() {
        let registry = StreamingTextAnimationRegistry()

        // The first projection predates this presentation and starts opaque.
        registry.observeProjectedStreams(["existing"], animatesNewStreams: true)
        #expect(!registry.presentation.claimInitialAnimation(for: "existing"))

        // A followed live-edge arrival reserves exactly one entrance.
        registry.observeProjectedStreams(
            ["existing", "visible-live"],
            animatesNewStreams: true
        )
        #expect(registry.presentation.claimInitialAnimation(for: "visible-live"))
        #expect(!registry.presentation.claimInitialAnimation(for: "visible-live"))

        // An arrival while the reader is away is opaque on first mount.
        registry.observeProjectedStreams(
            ["existing", "visible-live", "offscreen-live"],
            animatesNewStreams: false
        )
        #expect(!registry.presentation.claimInitialAnimation(for: "offscreen-live"))
    }

    @Test("Application suspension preserves unseen arrivals for foreground playback")
    func suspendedProjectionBacklog() {
        let registry = StreamingTextAnimationRegistry()
        registry.observeProjectedStreams([], animatesNewStreams: true)
        registry.suspendPlayback()
        registry.observeProjectedStreams(["background-row"], animatesNewStreams: false)
        registry.resumePlayback()

        #expect(registry.presentation.claimInitialAnimation(for: "background-row"))
        #expect(!registry.presentation.claimInitialAnimation(for: "background-row"))
    }

    @Test("The first post-foreground projection preserves a delayed UIKit delta")
    func postForegroundProjectionBacklog() {
        let registry = StreamingTextAnimationRegistry()
        registry.observeProjectedStreams(["before"], animatesNewStreams: true)
        registry.suspendPlayback()
        registry.resumePlayback()

        registry.observeProjectedStreams(
            ["before", "published-after-resume"],
            animatesNewStreams: false
        )
        #expect(
            registry.presentation.claimInitialAnimation(for: "published-after-resume")
        )
    }

    @Test("A remounted native row baselines a semantic stream already claimed by the surface")
    func remountedRowBaselines() {
        let presentation = StreamingTextAnimationPresentation()
        let firstMount = StreamingMarkdownAnimationMount()
        let remount = StreamingMarkdownAnimationMount()

        #expect(
            firstMount.resolve(streamID: "answer", presentation: presentation)
                .animatesInitialContent
        )
        let remountResolution = remount.resolve(
            streamID: "answer",
            presentation: presentation
        )
        #expect(!remountResolution.animatesInitialContent)
        #expect(remountResolution.needsActivation)
    }

    @Test("Response rows share one live cadence and release it after settlement")
    func responseCoordinatorLifetime() {
        let registry = StreamingTextAnimationRegistry()
        let first = registry.coordinator(for: "response")
        let second = registry.coordinator(for: "response")
        #expect(first === second)

        registry.retireCoordinator(for: "response")
        let replacement = registry.coordinator(for: "response")
        #expect(first !== replacement)
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

    @Test("A visibility generation settles only content that already exists")
    func presentationVisibilityGeneration() {
        let presentation = StreamingTextAnimationPresentation()
        presentation.establishBaseline { ["existing"] }
        presentation.updateVisibility(generation: 1, isVisible: true) { ["existing"] }
        let firstToken = presentation.settlementToken(for: "existing")
        #expect(firstToken != nil)

        #expect(presentation.claimInitialAnimation(for: "live"))
        presentation.updateVisibility(generation: 1, isVisible: true) { ["existing", "live"] }
        #expect(presentation.settlementToken(for: "live") == nil)

        presentation.updateVisibility(generation: 1, isVisible: false) { [] }
        #expect(!presentation.animationsEnabled)
        presentation.updateVisibility(generation: 2, isVisible: true) { ["existing", "live"] }
        #expect(presentation.animationsEnabled)
        #expect(presentation.settlementToken(for: "existing") != firstToken)
        #expect(presentation.settlementToken(for: "live") != nil)
    }

    @Test("Durable detail hydration settles one snapshot but not later live streams")
    func hydratedDetailsSettleOnce() {
        let presentation = StreamingTextAnimationPresentation()
        #expect(presentation.claimInitialAnimation(for: "hydrated"))
        presentation.settleRestoredStreams({ ["hydrated"] }, restorationID: 7)
        #expect(presentation.settlementToken(for: "hydrated") != nil)

        #expect(presentation.claimInitialAnimation(for: "later-live"))
        presentation.settleRestoredStreams(
            { ["hydrated", "later-live"] },
            restorationID: 7
        )
        #expect(presentation.settlementToken(for: "later-live") == nil)
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
