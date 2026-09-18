import Foundation

/// Opt-in diagnostic shared by the probe and the transport's decoder queue.
/// No fault is armed in the app. Time is supplied by the caller so the state
/// transitions can be checked without a codec, network, or scheduler.
package final class ScreenSharingDecoderRecoveryCheck: @unchecked Sendable {
  package init() {}
  package enum Action: Equatable {
    case accept
    case reset
    case rejectDelta
    case recovered(milliseconds: Double)
  }

  private let lock = NSLock()
  private var remainingFrames: Int?
  private var failedAtNs: Int64?
  private var onReset: (@Sendable () -> Void)?

  package func arm(afterFrames: Int, onReset: (@Sendable () -> Void)? = nil) {
    precondition(afterFrames > 0)
    lock.withLock {
      remainingFrames = afterFrames
      failedAtNs = nil
      self.onReset = onReset
    }
  }

  package func inspect(keyFrame: Bool, nowNs: Int64) -> Action {
    let result: (Action, (@Sendable () -> Void)?) = lock.withLock {
      if let failedAtNs {
        guard keyFrame else { return (.rejectDelta, nil) }
        self.failedAtNs = nil
        return (.recovered(milliseconds: Double(max(0, nowNs - failedAtNs)) / 1_000_000), nil)
      }
      guard let remainingFrames else { return (.accept, nil) }
      if remainingFrames > 1 {
        self.remainingFrames = remainingFrames - 1
        return (.accept, nil)
      }
      self.remainingFrames = nil
      failedAtNs = nowNs
      let callback = onReset
      onReset = nil
      return (.reset, callback)
    }
    result.1?()
    return result.0
  }
}
