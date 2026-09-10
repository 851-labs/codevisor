import CodevisorTestSupport
import Foundation
import Observation
import Testing
@testable import StreamMarkdown

@MainActor
@Suite("Streaming text observation")
struct StreamingTextAnimationObservationTests {
  @Test("An idle retained row observes its baseline before the first live append")
  func idleRetainedRowObservesBaseline() throws {
    let registry = StreamingTextAnimationRegistry()
    registry.observeProjectedStreams(["response"], animatesNewStreams: true)
    let coordinator = registry.coordinator(for: "response")
    let mount = StreamingMarkdownAnimationMount()
    let first = mount.resolve(streamID: "response", presentation: registry.presentation)
    _ = mount.activate(token: first.activationToken)
    let invalidated = TestSignal()
    withObservationTracking {
      _ = coordinator.playbackRevision
      _ = coordinator.hasActiveEntranceAnimation
    } onChange: {
      invalidated.signal()
    }

    registry.prepareForPresentation()
    registry.observeProjectedStreams(["response"], animatesNewStreams: true)
    // SwiftUI must reevaluate even when text and animation activity have not
    // changed. Otherwise the next live append becomes the baseline render.
    try #require(invalidated.value == 1)
    let baseline = mount.resolve(streamID: "response", presentation: registry.presentation)
    #expect(!baseline.animatesInitialContent)
    let state = StreamingTextAnimationState()
    func prepare(_ text: String, animates: Bool, now: TimeInterval) -> PreparedStreamingText {
      state.prepare(
        NSAttributedString(string: text),
        context: .init(
          timeline: coordinator.timeline, sourceID: "response", documentSource: text,
          isStreaming: true, animatesInitialContent: animates, reduceMotion: false,
          playbackRevision: coordinator.playbackRevision
        ), now: now
      )
    }
    #expect(prepare("Restored text", animates: false, now: 10).activeAnimationRanges.isEmpty)
    #expect(mount.activate(token: baseline.activationToken))
    let live = mount.resolve(streamID: "response", presentation: registry.presentation)
    #expect(
      !prepare("Restored text plus live words", animates: live.animatesInitialContent, now: 11).activeAnimationRanges
        .isEmpty)
  }
}
