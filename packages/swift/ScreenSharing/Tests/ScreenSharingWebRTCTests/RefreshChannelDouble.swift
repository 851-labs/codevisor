import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

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

func nanoseconds(_ duration: Duration) -> Int64 {
  duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
}
