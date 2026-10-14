#if canImport(AppKit)
  import AppKit
  import Testing

  @testable import StreamMarkdown

  @MainActor
  @Suite("Transcript horizontal scroll routing")
  struct TranscriptHorizontalScrollViewTests {
    private final class RecordingTranscript: NSScrollView {
      var scrollEvents = 0

      override func scrollWheel(with event: NSEvent) {
        scrollEvents += 1
      }
    }

    private final class BoundedOutput: TranscriptHorizontalScrollView {
      var canScrollDown = true

      override func shouldConsumeVerticalScroll(_ event: NSEvent) -> Bool {
        event.scrollingDeltaY < 0 && canScrollDown
      }
    }

    private struct Mounted {
      let transcript: RecordingTranscript
      let output: BoundedOutput
    }

    private func mount(documentWidth: CGFloat) -> Mounted {
      let transcript = RecordingTranscript(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      transcript.hasVerticalScroller = true
      let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2_000))
      transcript.documentView = document
      let output = BoundedOutput(frame: NSRect(x: 20, y: 20, width: 500, height: 200))
      output.hasVerticalScroller = true
      output.documentView = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: 1_000))
      document.addSubview(output)
      return Mounted(transcript: transcript, output: output)
    }

    private enum Phase: Int64 {
      case began = 1
      case changed = 2
      case ended = 4
    }

    private func event(_ phase: Phase, deltaY: Int32, flags: CGEventFlags = []) throws -> NSEvent {
      let cgEvent = try #require(
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: 0, wheel3: 0))
      cgEvent.flags = flags
      cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
      return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func swipeDown(over output: BoundedOutput, flags: CGEventFlags = []) throws {
      output.scrollWheel(with: try event(.began, deltaY: 0, flags: flags))
      output.scrollWheel(with: try event(.changed, deltaY: -12, flags: flags))
      output.scrollWheel(with: try event(.changed, deltaY: -12, flags: flags))
      output.scrollWheel(with: try event(.ended, deltaY: 0, flags: flags))
    }

    @Test("A swipe that begins motionless over long lines still hands off at the bottom")
    func motionlessStartOverWideOutputHandsOff() throws {
      let mounted = mount(documentWidth: 1_400)
      mounted.output.canScrollDown = false
      try swipeDown(over: mounted.output)
      #expect(mounted.transcript.scrollEvents == 3)
    }

    @Test("Holding Shift keeps a swipe over long lines on the output's horizontal axis")
    func shiftedSwipeOverWideOutputStaysInIt() throws {
      let mounted = mount(documentWidth: 1_400)
      mounted.output.canScrollDown = false
      try swipeDown(over: mounted.output, flags: .maskShift)
      #expect(mounted.transcript.scrollEvents == 0)
    }

    @Test("A swipe that begins motionless over fitting lines scrolls the output it is over")
    func motionlessStartOverNarrowOutputScrollsIt() throws {
      let mounted = mount(documentWidth: 400)
      try swipeDown(over: mounted.output)
      #expect(mounted.transcript.scrollEvents == 0)
    }
  }
#endif
