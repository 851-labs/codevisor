#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing

  @testable import StreamMarkdown

  @MainActor
  @Suite("Height-limited scroll chaining")
  struct HeightLimitedScrollContainerTests {
    private final class RecordingTranscript: NSScrollView {
      var scrollEvents = 0

      override func scrollWheel(with event: NSEvent) {
        scrollEvents += 1
      }
    }

    private struct Mounted {
      let transcript: RecordingTranscript
      let container: HeightLimitedScrollContainer
    }

    private func mount(contentHeight: CGFloat) -> Mounted {
      let transcript = RecordingTranscript(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      transcript.hasVerticalScroller = true
      let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2_000))
      transcript.documentView = document
      let container = HeightLimitedScrollContainer()
      container.maxHeight = 200
      container.setContent(Color.clear.frame(height: contentHeight))
      let size = container.fit(toWidth: 500) ?? .zero
      container.frame = NSRect(origin: CGPoint(x: 20, y: 20), size: size)
      document.addSubview(container)
      container.layoutSubtreeIfNeeded()
      return Mounted(transcript: transcript, container: container)
    }

    private enum Phase {
      case began, changed, ended, momentum, momentumEnded

      var scrollPhase: Int64 {
        switch self {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .momentum, .momentumEnded: 0
        }
      }

      var momentumPhase: Int64 {
        switch self {
        case .momentum: 2
        case .momentumEnded: 3
        default: 0
        }
      }
    }

    private func event(_ phase: Phase, deltaY: Int32) throws -> NSEvent {
      let cgEvent = try #require(
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: 0, wheel3: 0))
      cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.scrollPhase)
      cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase.momentumPhase)
      return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func swipeDownWithMomentum(over container: HeightLimitedScrollContainer) throws {
      container.scrollWheel(with: try event(.began, deltaY: 0))
      container.scrollWheel(with: try event(.changed, deltaY: -12))
      container.scrollWheel(with: try event(.changed, deltaY: -12))
      container.scrollWheel(with: try event(.ended, deltaY: 0))
      container.scrollWheel(with: try event(.momentum, deltaY: -8))
      container.scrollWheel(with: try event(.momentumEnded, deltaY: 0))
    }

    private func scrollToEnd(_ container: HeightLimitedScrollContainer) throws {
      let documentHeight = try #require(container.documentView).frame.height
      container.contentView.scroll(to: CGPoint(x: 0, y: documentHeight - container.contentView.bounds.height))
      container.reflectScrolledClipView(container.contentView)
    }

    @Test("A preview taller than its limit keeps a swipe that still has content to reveal")
    func overflowingPreviewScrollsItself() throws {
      let mounted = mount(contentHeight: 1_000)
      #expect(mounted.container.frame.height == 200)
      try swipeDownWithMomentum(over: mounted.container)
      #expect(mounted.transcript.scrollEvents == 0)
    }

    @Test("A preview scrolled to its end hands the swipe and its momentum to the transcript")
    func previewAtEndHandsOff() throws {
      let mounted = mount(contentHeight: 1_000)
      try scrollToEnd(mounted.container)
      try swipeDownWithMomentum(over: mounted.container)
      #expect(mounted.transcript.scrollEvents == 5)
    }

    @Test("A preview that fits its limit sends every swipe to the transcript")
    func fittingPreviewHandsOff() throws {
      let mounted = mount(contentHeight: 120)
      #expect(mounted.container.frame.height == 120)
      try swipeDownWithMomentum(over: mounted.container)
      #expect(mounted.transcript.scrollEvents == 6)
    }
  }
#endif
