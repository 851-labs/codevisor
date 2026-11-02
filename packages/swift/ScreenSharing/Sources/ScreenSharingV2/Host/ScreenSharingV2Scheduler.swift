import Dispatch
import ScreenSharing

protocol ScreenSharingV2Scheduler: Sendable {
  var nowNs: Int64 { get }
  func run(afterNs delayNs: Int64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void)
}

struct ScreenSharingV2SystemScheduler: ScreenSharingV2Scheduler {
  var nowNs: Int64 { ScreenSharingMetrics.nowNs }

  func run(afterNs delayNs: Int64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: max(0, delayNs))), execute: work)
  }
}
