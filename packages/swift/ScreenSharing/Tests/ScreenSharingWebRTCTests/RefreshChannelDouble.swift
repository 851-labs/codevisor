import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

/// The refresh protocol's channel contract without a transport. Availability is
/// owned by the test so the deferred and the delivered paths are both reachable,
/// and both outcomes of a send are signalled so a test waits for the attempt as
/// an event rather than guessing when it happened.
@MainActor
final class RefreshChannelDouble: ScreenSharingMessageChannel {
  var onMessage: ((ScreenSharingVideoRefreshMessage) -> Void)?
  var onAvailabilityChanged: ((Bool) -> Void)?
  var isAvailable = true
  private(set) var sent: [ScreenSharingVideoRefreshMessage] = []
  let sends = TestSignal()
  let rejections = TestSignal()

  @discardableResult
  func send(_ message: ScreenSharingVideoRefreshMessage) -> Bool {
    guard isAvailable else {
      rejections.signal()
      return false
    }
    sent.append(message)
    sends.signal()
    return true
  }

  func close() {
    isAvailable = false
    onAvailabilityChanged?(false)
  }
}

/// Virtual nanoseconds since a `TestClock`'s origin, so the schedules that read
/// a monotonic clock and the schedules that sleep share one controlled timeline.
func nanoseconds(_ duration: Duration) -> Int64 {
  duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
}
