#if os(macOS)
  import CoreGraphics
  import Synchronization

  final class ScreenSharingCaptureChanges: Sendable {
    private struct State {
      var followsDeliveredFrame = false
      var reconfigurations = 0
    }

    private let state = Mutex(State())

    func interrupt() {
      state.withLock { $0.followsDeliveredFrame = false }
    }

    func reconfigurationBegan() {
      state.withLock { state in
        state.reconfigurations += 1
        state.followsDeliveredFrame = false
      }
    }

    func reconfigurationEnded() {
      state.withLock { state in
        state.reconfigurations -= 1
        state.followsDeliveredFrame = false
      }
    }

    func sinceLastDeliveredFrame(_ reported: [CGRect]?) -> [CGRect]? {
      let followsDeliveredFrame = state.withLock { state in
        defer { state.followsDeliveredFrame = state.reconfigurations == 0 }
        return state.followsDeliveredFrame
      }
      guard followsDeliveredFrame, let reported, reported.contains(where: { !$0.isEmpty }) else { return nil }

      return reported
    }
  }
#endif
