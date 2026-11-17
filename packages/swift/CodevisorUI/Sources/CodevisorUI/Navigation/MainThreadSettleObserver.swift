import Foundation

@MainActor
final class MainThreadSettleObserver {
  static let quietNanoseconds: UInt64 = 100_000_000
  static let limitNanoseconds: UInt64 = 2_000_000_000
  private static let neverFires: CFTimeInterval = 1_000_000_000

  private var settle: MainThreadSettle
  private var observer: CFRunLoopObserver?
  private var wakeTimer: CFRunLoopTimer?
  private let onResult: (MainThreadSettle.Result) -> Void

  init(onResult: @escaping (MainThreadSettle.Result) -> Void) {
    self.onResult = onResult
    settle = MainThreadSettle(
      start: DispatchTime.now().uptimeNanoseconds, quietNanoseconds: Self.quietNanoseconds,
      limitNanoseconds: Self.limitNanoseconds)
    install()
  }

  func cancel() {
    if let observer { CFRunLoopObserverInvalidate(observer) }
    if let wakeTimer { CFRunLoopTimerInvalidate(wakeTimer) }
    observer = nil
    wakeTimer = nil
  }

  private func install() {
    let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
    let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CFIndex.max) {
      [weak self] _, activity in
      MainActor.assumeIsolated { self?.runLoopChanged(to: activity) }
    }
    let wakeTimer = CFRunLoopTimerCreateWithHandler(
      kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.neverFires, Self.neverFires, 0, 0
    ) { _ in }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    CFRunLoopAddTimer(CFRunLoopGetMain(), wakeTimer, .commonModes)
    self.observer = observer
    self.wakeTimer = wakeTimer
  }

  private func runLoopChanged(to activity: CFRunLoopActivity) {
    let now = DispatchTime.now().uptimeNanoseconds
    if activity == .beforeWaiting {
      settle.willSleep(at: now)
      wakeAfterQuietInterval()
      return
    }
    guard let result = settle.didWake(at: now) else { return }

    cancel()
    onResult(result)
  }

  private func wakeAfterQuietInterval() {
    guard let wakeTimer else { return }

    let quietSeconds = CFTimeInterval(Self.quietNanoseconds) / 1_000_000_000
    CFRunLoopTimerSetNextFireDate(wakeTimer, CFAbsoluteTimeGetCurrent() + quietSeconds)
  }
}
