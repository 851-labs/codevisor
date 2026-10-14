import AppKit

final class FlippedTranscriptDocumentView: NSView {
  override var isFlipped: Bool { true }

  private var transcript: VirtualizedTranscriptScrollView? {
    enclosingScrollView as? VirtualizedTranscriptScrollView
  }

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
