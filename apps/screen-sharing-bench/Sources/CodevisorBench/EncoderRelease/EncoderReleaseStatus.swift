import Foundation
import Synchronization

final class EncoderReleaseStatus: Sendable {
  static let timeout = DispatchTimeInterval.seconds(2)

  private let status = Mutex<OSStatus>(-1)
  private let done = DispatchSemaphore(value: 0)

  func finish(_ value: OSStatus) {
    status.withLock { $0 = value }
    done.signal()
  }

  func wait() -> OSStatus {
    guard done.wait(timeout: .now() + Self.timeout) == .success else { return -1 }

    return status.withLock { $0 }
  }
}
