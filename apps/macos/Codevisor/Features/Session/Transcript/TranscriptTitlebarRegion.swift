import AppKit

final class TranscriptTitlebarRegion: NSView {
  var press: @MainActor (NSEvent, NSWindow) -> Void = TranscriptTitlebarRegion.pressTitlebar

  func cover(topOf clipView: NSClipView, height: CGFloat, in scrollView: NSScrollView) {
    if superview !== scrollView { scrollView.addSubview(self) }
    let band = NSRect(origin: clipView.bounds.origin, size: NSSize(width: clipView.bounds.width, height: height))
    frame = scrollView.convert(band, from: clipView)
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    press(event, window)
  }

  override func rightMouseDown(with _: NSEvent) {}

  private static func pressTitlebar(_ event: NSEvent, in window: NSWindow) {
    guard event.clickCount == 2 else {
      window.performDrag(with: event)
      return
    }
    TitlebarDoubleClickAction(defaults: .standard).perform(on: window)
  }
}
