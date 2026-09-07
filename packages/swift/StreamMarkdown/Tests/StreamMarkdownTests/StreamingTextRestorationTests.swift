import Foundation
import Testing
@testable import StreamMarkdown

@MainActor
@Suite("Streaming text restoration")
struct StreamingTextRestorationTests {
  @Test("Delayed worked details are opaque and subsequent words and rows animate")
  func delayedWorkedDetails() {
    let registry = StreamingTextAnimationRegistry()
    registry.prepareForPresentation()
    registry.observeProjectedStreams(["summary"], animatesNewStreams: true)
    let summarySettlement = registry.presentation.settlementToken(for: "summary")

    // The compact snapshot is already presented. Hydration introduces
    // historical rows and can replace text in an existing summary row.
    // Another provider revision may already be awaiting projection.
    registry.observeProjectedStreams(
      ["summary", "work"],
      animatesNewStreams: true,
      initialProjectionIsPending: true,
      restorationID: "turn:7"
    )
    #expect(registry.presentation.settlementToken(for: "summary") != summarySettlement)
    let settlement = registry.presentation.settlementToken(for: "work")
    #expect(settlement != nil)

    let mount = StreamingMarkdownAnimationMount()
    let state = StreamingTextAnimationState()
    let timeline = StreamingTextAnimationTimeline()
    let baseline = mount.resolve(streamID: "work", presentation: registry.presentation)
    let restored = state.prepare(
      NSAttributedString(string: "Already here"),
      context: context(timeline, text: "Already here", animates: baseline.animatesInitialContent),
      now: 1
    )
    #expect(!baseline.animatesInitialContent)
    #expect(restored.activeAnimationRanges.isEmpty)
    #expect(restored.latestAnimationEnd == nil)
    #expect(mount.activate(token: baseline.activationToken))

    // Hydration provenance stays on the turn during subsequent live
    // updates. It must not repeatedly settle its growing text or new rows.
    registry.observeProjectedStreams(
      ["summary", "work", "live"],
      animatesNewStreams: true,
      initialProjectionIsPending: true,
      restorationID: "turn:7"
    )
    #expect(registry.presentation.settlementToken(for: "work") == settlement)
    #expect(registry.presentation.claimInitialAnimation(for: "live"))
    let live = mount.resolve(streamID: "work", presentation: registry.presentation)
    let appended = state.prepare(
      NSAttributedString(string: "Already here new words"),
      context: context(timeline, text: "Already here new words", animates: live.animatesInitialContent),
      now: 2
    )
    #expect(live.animatesInitialContent)
    #expect(appended.text.attribute(.streamMarkdownFade, at: 0, effectiveRange: nil) == nil)
    #expect(appended.text.attribute(.streamMarkdownFade, at: 8, effectiveRange: nil) == nil)
    #expect(appended.text.attribute(.streamMarkdownFade, at: 13, effectiveRange: nil) != nil)
  }

  @Test("Restoration cancels existing entrance reservations before rows mount")
  func restoredReservation() {
    let registry = StreamingTextAnimationRegistry()
    registry.observeProjectedStreams([], animatesNewStreams: true)
    registry.observeProjectedStreams(["work"], animatesNewStreams: true)
    registry.observeProjectedStreams(
      ["work"], animatesNewStreams: true, restorationID: "turn:7"
    )
    #expect(!registry.presentation.claimInitialAnimation(for: "work"))
  }

  @Test("An empty restored projection does not settle the next live text")
  func emptyRestoration() {
    let registry = StreamingTextAnimationRegistry()
    registry.prepareForPresentation()
    registry.observeProjectedStreams(
      [], animatesNewStreams: true, initialProjectionIsPending: true
    )
    registry.observeProjectedStreams(
      [], animatesNewStreams: true, initialProjectionIsPending: true, restorationID: "turn:7"
    )
    registry.observeProjectedStreams(
      ["live"], animatesNewStreams: true, restorationID: "turn:7"
    )
    #expect(registry.presentation.claimInitialAnimation(for: "live"))
  }

  @Test("A later restoration settles again without resetting on ordinary projections")
  func laterRestoration() {
    let registry = StreamingTextAnimationRegistry()
    registry.observeProjectedStreams(
      ["work"], animatesNewStreams: true, restorationID: "turn:7"
    )
    let first = registry.presentation.settlementToken(for: "work")
    registry.observeProjectedStreams(
      ["work"], animatesNewStreams: true, restorationID: "turn:8"
    )
    #expect(registry.presentation.settlementToken(for: "work") != first)
  }

  private func context(
    _ timeline: StreamingTextAnimationTimeline,
    text: String,
    animates: Bool
  ) -> StreamingTextAnimationContext {
    StreamingTextAnimationContext(
      timeline: timeline,
      sourceID: "work",
      documentSource: text,
      isStreaming: true,
      animatesInitialContent: animates,
      reduceMotion: false
    )
  }
}
