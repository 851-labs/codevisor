import Foundation
import Testing
@testable import StreamMarkdown

@MainActor
@Suite("Streaming text animation state")
struct StreamingTextAnimationStateTests {
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

  @Test("A structural contraction does not replay its visible word prefix")
  func structuralContractionPreservesVisiblePrefix() {
    let timeline = StreamingTextAnimationTimeline()
    let state = StreamingTextAnimationState()
    let original = state.prepare(
      NSAttributedString(string: "Before image Alt trailing"),
      context: StreamingTextAnimationContext(
        timeline: timeline,
        sourceID: "response-segment-0",
        documentSource: "Before image ![Alt](./image.png) trailing",
        isStreaming: true,
        animatesInitialContent: true,
        reduceMotion: false
      ),
      now: 1
    )
    let originalPrefixFades = [0, 7].compactMap {
      original.text.attribute(
        .streamMarkdownFade,
        at: $0,
        effectiveRange: nil
      ) as? StreamingTextFadeMetadata
    }
    #expect(originalPrefixFades.count == 2)

    // Once the image destination becomes a native preview, this surface
    // retains only the Markdown before it. Those words were already fully
    // visible and must not be scheduled again.
    let contracted = state.prepare(
      NSAttributedString(string: "Before image "),
      context: StreamingTextAnimationContext(
        timeline: timeline,
        sourceID: "response-segment-0",
        documentSource: "Before image ",
        isStreaming: true,
        animatesInitialContent: true,
        reduceMotion: false
      ),
      now: 2
    )

    #expect(contracted.latestAnimationEnd == nil)
    #expect(contracted.activeAnimationRanges.isEmpty)
    #expect(contracted.text.attribute(.streamMarkdownFade, at: 0, effectiveRange: nil) == nil)
    #expect(contracted.text.attribute(.streamMarkdownFade, at: 7, effectiveRange: nil) == nil)
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
