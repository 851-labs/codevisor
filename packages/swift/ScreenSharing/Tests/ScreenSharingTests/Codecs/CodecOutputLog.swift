import CodevisorTestSupport
import Foundation
@testable import ScreenSharing

final class CodecOutputLog<Item>: @unchecked Sendable {
  private struct Mark {
    let items: Int
    let failures: Int
  }

  private let lock = NSLock()
  private var stored: [Item] = []
  private var failures: [OSStatus] = []
  private let changed = TestSignal()

  var items: [Item] { lock.withLock { stored } }
  var sessionFailures: [OSStatus] { lock.withLock { failures } }

  func record(_ item: Item) {
    lock.withLock { stored.append(item) }
    changed.signal()
  }

  func recordSessionFailure(_ status: OSStatus) {
    lock.withLock { failures.append(status) }
    changed.signal()
  }

  func follow(_ encoder: ScreenSharingEncoder) where Item == ScreenSharingEncodedFrame {
    encoder.onFrame { self.record($0) }
    encoder.onSessionFailure { self.recordSessionFailure($0) }
  }

  func nextItem(after submit: () throws -> Void) async rethrows -> Item? {
    let mark = lock.withLock { Mark(items: stored.count, failures: failures.count) }
    try submit()
    await changed.cancellableWait { settled(since: mark) }
    return lock.withLock { stored.count > mark.items ? stored[mark.items] : nil }
  }

  private func settled(since mark: Mark) -> Bool {
    lock.withLock { stored.count > mark.items || failures.count > mark.failures }
  }
}
