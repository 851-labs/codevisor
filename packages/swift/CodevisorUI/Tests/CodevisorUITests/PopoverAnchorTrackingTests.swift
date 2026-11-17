#if os(macOS)
  import AppKit
  import Testing

  @testable import CodevisorUI

  @MainActor
  @Suite("Anchored popovers")
  struct PopoverAnchorTrackingTests {
    @MainActor
    private final class Transcript {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: .borderless, backing: .buffered,
        defer: false)
      let scrollView = NSScrollView(frame: NSRect(x: 0, y: 100, width: 600, height: 400))
      let anchor = PopoverAnchorTrackingView(frame: NSRect(x: 100, y: 1_000, width: 120, height: 20))
      var dismissals = 0

      init() {
        window.isReleasedWhenClosed = false
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 4_000))
        document.addSubview(anchor)
        scrollView.documentView = document
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView?.addSubview(scrollView)
        anchor.onAnchorScrolled = { [unowned self] in dismissals += 1 }
        scroll(toY: 900)
      }

      func scroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
      }
    }

    private final class FlippedView: NSView {
      override var isFlipped: Bool { true }
    }

    @Test("Scrolling the transcript dismisses the popover, scrolling inside it or elsewhere does not")
    func scrollWheelOwnership() {
      let transcript = Transcript()
      let popoverWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless, backing: .buffered,
        defer: false)
      popoverWindow.isReleasedWhenClosed = false
      let overTranscript = NSPoint(x: 300, y: 300)
      let belowTranscript = NSPoint(x: 300, y: 50)

      #expect(transcript.anchor.scrollMovesAnchor(window: transcript.window, locationInWindow: overTranscript))
      #expect(!transcript.anchor.scrollMovesAnchor(window: popoverWindow, locationInWindow: overTranscript))
      #expect(!transcript.anchor.scrollMovesAnchor(window: transcript.window, locationInWindow: belowTranscript))
    }

    @Test("A popover whose anchor scrolls out of view is dismissed instead of pinning to the edge")
    func anchorScrolledAway() {
      let transcript = Transcript()

      transcript.scroll(toY: 990)
      #expect(transcript.dismissals == 0)

      transcript.scroll(toY: 1_200)
      #expect(transcript.dismissals > 0)
    }
  }
#endif
