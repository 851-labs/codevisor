import Dispatch

package struct ScreenSharingRenderClock: Sendable {
  package let now: @Sendable () -> Int64
  package let after: @Sendable (_ delayNs: Int64, _ work: @escaping @Sendable @MainActor () -> Void) -> Void

  package init(
    now: @escaping @Sendable () -> Int64,
    after: @escaping @Sendable (_ delayNs: Int64, _ work: @escaping @Sendable @MainActor () -> Void) -> Void
  ) {
    self.now = now
    self.after = after
  }

  package static let system = ScreenSharingRenderClock(
    now: { ScreenSharingMetrics.nowNs },
    after: { delayNs, work in
      DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(max(0, delayNs)))) {
        MainActor.assumeIsolated { work() }
      }
    })
}
