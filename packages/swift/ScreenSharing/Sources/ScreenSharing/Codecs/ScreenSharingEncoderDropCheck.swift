import Foundation

/// Single-use probe fault, armed at the decoder reset edge. The app never arms it.
package final class ScreenSharingEncoderDropCheck: @unchecked Sendable {
  package init() {}
  private let lock = NSLock()
  private var armed = false

  package func arm() { lock.withLock { armed = true } }

  package func consume() -> Bool {
    lock.withLock {
      guard armed else { return false }
      armed = false
      return true
    }
  }
}
