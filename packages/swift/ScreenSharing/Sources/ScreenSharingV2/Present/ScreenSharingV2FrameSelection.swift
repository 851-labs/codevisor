import ScreenSharing

struct ScreenSharingV2FrameSelection {
  private var lastFrame: ScreenSharingVideoFrame?
  private var needsRedraw = false

  mutating func select(from mailbox: ScreenSharingFrameMailbox) -> (frame: ScreenSharingVideoFrame, isNew: Bool)? {
    if let incoming = mailbox.take() {
      lastFrame = incoming
      needsRedraw = false
      return (incoming, true)
    }
    guard needsRedraw, let lastFrame else { return nil }

    needsRedraw = false
    return (lastFrame, false)
  }

  mutating func redraw() {
    needsRedraw = true
  }

  mutating func clear() {
    lastFrame = nil
    needsRedraw = false
  }
}
