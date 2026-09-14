import Foundation

/// Single-use probe fault, armed at the decoder reset edge. The app never arms it.
final class ScreenSharingEncoderDropCheck: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false

  func arm() { lock.withLock { armed = true } }

  func consume() -> Bool {
    lock.withLock {
      guard armed else { return false }
      armed = false
      return true
    }
  }
}
