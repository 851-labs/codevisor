import AppKit

@MainActor
final class TranscriptQuoteHighlightView: NSView {
  static let holdDuration: Duration = .milliseconds(1600)
  static let fadeDuration: TimeInterval = 0.9

  private var rects: [NSRect] = []
  private var fadeTask: Task<Void, Never>?

  override var isFlipped: Bool { true }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  func show(_ documentRects: [NSRect]) {
    fadeTask?.cancel()
    layer?.removeAllAnimations()
    alphaValue = 1
    isHidden = false
    place(documentRects)
    fadeTask = Task { [weak self] in
      try? await Task.sleep(for: Self.holdDuration)
      guard !Task.isCancelled else { return }
      self?.fadeOut()
    }
  }

  func place(_ documentRects: [NSRect]) {
    guard let bounds = documentRects.first.map({ documentRects.dropFirst().reduce($0) { $0.union($1) } }) else {
      return clear()
    }
    frame = bounds.insetBy(dx: -Self.outset, dy: -Self.outset)
    rects = documentRects.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
    needsDisplay = true
  }

  func clear() {
    fadeTask?.cancel()
    fadeTask = nil
    rects = []
    isHidden = true
  }

  override func draw(_: NSRect) {
    NSColor.controlAccentColor.withAlphaComponent(Self.fillAlpha).setFill()
    for rect in rects {
      NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
    }
  }

  private func fadeOut() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.alphaValue == 0 else { return }
        self.clear()
      }
    }
  }

  private static let outset: CGFloat = 2
  private static let fillAlpha: CGFloat = 0.3
}
