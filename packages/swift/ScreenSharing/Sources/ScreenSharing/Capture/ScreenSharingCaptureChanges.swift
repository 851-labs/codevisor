#if os(macOS)
  import CoreGraphics
  import Synchronization

  final class ScreenSharingCaptureChanges: Sendable {
    private let followsDeliveredFrame = Mutex(false)

    func interrupt() {
      followsDeliveredFrame.withLock { $0 = false }
    }

    func sinceLastDeliveredFrame(_ reported: [CGRect]?) -> [CGRect]? {
      let followsDeliveredFrame = followsDeliveredFrame.withLock { follows in
        defer { follows = true }
        return follows
      }
      guard followsDeliveredFrame, let reported, reported.contains(where: { !$0.isEmpty }) else { return nil }

      return reported
    }
  }
#endif
