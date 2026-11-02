#if os(macOS)
  import AppKit
  import Testing

  @testable import CodevisorUI

  @MainActor
  @Suite("Inline plugin app scrolling")
  struct PluginAppInlineScrollTests {
    private final class RecordingTranscript: NSScrollView {
      var scrollDeltas: [CGFloat] = []

      override func scrollWheel(with event: NSEvent) {
        scrollDeltas.append(event.scrollingDeltaY)
      }
    }

    private struct Phases: Equatable {
      let scroll: Int64
      let momentum: Int64

      static let began = Phases(scroll: 1, momentum: 0)
      static let changed = Phases(scroll: 2, momentum: 0)
      static let ended = Phases(scroll: 4, momentum: 0)
      static let momentum = Phases(scroll: 0, momentum: 2)
      static let momentumEnded = Phases(scroll: 0, momentum: 3)
      static let none = Phases(scroll: 0, momentum: 0)
    }

    private func mountedApp() -> (RecordingTranscript, NSView) {
      let transcript = RecordingTranscript(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      transcript.hasVerticalScroller = true
      let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2_000))
      transcript.documentView = document
      let webView = PluginAppWebController().webView
      webView.frame = NSRect(x: 20, y: 20, width: 560, height: 300)
      document.addSubview(webView)
      return (transcript, webView)
    }

    private func event(_ phases: Phases, deltaX: Int32 = 0, deltaY: Int32 = 0) throws -> NSEvent {
      let cgEvent = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0))
      cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: phases == .none ? 0 : 1)
      cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phases.scroll)
      cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phases.momentum)
      return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func swipe(over view: NSView, deltaX: Int32, deltaY: Int32) throws {
      view.scrollWheel(with: try event(.began))
      view.scrollWheel(with: try event(.changed, deltaX: deltaX, deltaY: deltaY))
      view.scrollWheel(with: try event(.changed, deltaX: deltaX / 2, deltaY: deltaY))
      view.scrollWheel(with: try event(.ended))
      view.scrollWheel(with: try event(.momentum, deltaX: deltaX / 3, deltaY: deltaY / 3))
      view.scrollWheel(with: try event(.momentumEnded))
    }

    @Test("A vertical swipe over an inline app scrolls the transcript, momentum included")
    func verticalSwipeScrollsTranscript() throws {
      let (transcript, app) = mountedApp()

      try swipe(over: app, deltaX: 4, deltaY: -12)

      #expect(transcript.scrollDeltas == [-12, -12, 0, -4, 0])
    }

    @Test("A sideways swipe stays with the app, even when it drifts vertically")
    func horizontalSwipeStaysInApp() throws {
      let (transcript, app) = mountedApp()

      try swipe(over: app, deltaX: -24, deltaY: 6)

      #expect(transcript.scrollDeltas.isEmpty)
    }

    @Test("A mouse wheel over an inline app scrolls the transcript")
    func mouseWheelScrollsTranscript() throws {
      let (transcript, app) = mountedApp()

      app.scrollWheel(with: try event(.none, deltaY: -3))

      #expect(transcript.scrollDeltas.count == 1)
    }
  }
#endif
