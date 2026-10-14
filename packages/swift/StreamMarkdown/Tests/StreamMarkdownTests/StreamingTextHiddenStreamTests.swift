import Testing
@testable import StreamMarkdown

@MainActor
struct StreamingTextHiddenStreamTests {
  @Test("Text hidden by a collapsed disclosure is presented when revealed; later text animates")
  func hiddenStreams() {
    let registry = StreamingTextAnimationRegistry()
    registry.observeProjectedStreams(["header"], animatesNewStreams: true)
    registry.observeProjectedStreams(["header"], animatesNewStreams: true)
    registry.observeHiddenStreams(["part-1", "part-2"])
    registry.observeProjectedStreams(["header", "part-1", "part-2"], animatesNewStreams: true)
    registry.observeProjectedStreams(["header", "part-1", "part-2", "part-3"], animatesNewStreams: true)

    #expect(!registry.presentation.claimInitialAnimation(for: "part-1"))
    #expect(!registry.presentation.claimInitialAnimation(for: "part-2"))
    #expect(registry.presentation.claimInitialAnimation(for: "part-3"))
  }
}
