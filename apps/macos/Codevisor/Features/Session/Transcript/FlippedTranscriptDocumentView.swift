import AppKit

final class FlippedTranscriptDocumentView: NSView {
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    autoresizingMask = [.width]
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    centerRowColumn()
  }

  private func centerRowColumn() {
    let columnWidth = VirtualizedTranscriptScrollView.rowWidth(forViewportWidth: frame.width)
    let leading = (frame.width - columnWidth) / 2
    guard abs(bounds.minX + leading) > 0.01 else { return }
    setBoundsOrigin(NSPoint(x: -leading, y: bounds.minY))
    transcript?.rowColumnDidMove()
  }

  override func layout() {
    super.layout()
    transcript?.commitMeasurementsInLayoutPass()
  }

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
