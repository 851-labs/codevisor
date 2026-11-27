import Foundation

final class ScreenSharingTakenFrame: @unchecked Sendable {
  private let lock = NSLock()
  private var taken: ScreenSharingVideoFrame?

  var frame: ScreenSharingVideoFrame? { lock.withLock { taken } }

  func discard() {
    lock.withLock { taken = nil }
  }

  func take(from mailbox: ScreenSharingFrameMailbox) -> ScreenSharingVideoFrame? {
    let frame = mailbox.take()
    if let frame { lock.withLock { taken = frame } }
    return frame
  }
}
