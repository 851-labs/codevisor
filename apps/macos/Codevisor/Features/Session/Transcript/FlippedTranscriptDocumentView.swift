import AppKit

final class FlippedTranscriptDocumentView: NSView {
  override var isFlipped: Bool { true }

  private var transcript: VirtualizedTranscriptScrollView? {
    enclosingScrollView as? VirtualizedTranscriptScrollView
  }

  // Clicks on row chrome and the spacing between rows bubble up here.
  // Hand them to the transcript-wide selection so a drag that starts in
  // the margin still selects text.
  override func mouseDown(with event: NSEvent) {
    guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
      let transcript, transcript.beginTranscriptSelection(withDocumentClick: event)
    else {
      super.mouseDown(with: event)
      return
    }
  }

  override func mouseDragged(with event: NSEvent) {
    transcript?.continueTranscriptSelection(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    transcript?.endTranscriptSelection(with: event)
  }
}
