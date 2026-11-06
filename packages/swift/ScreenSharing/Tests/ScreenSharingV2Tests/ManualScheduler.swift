import CodevisorTestSupport
import Dispatch
import Synchronization

@testable import ScreenSharingV2

final class ManualScheduler: ScreenSharingV2Scheduler {
  private struct Work {
    let dueNs: Int64
    let run: @Sendable () -> Void
  }

  private struct State {
    var nowNs: Int64 = 1_000_000_000
    var queue: DispatchQueue?
    var works: [Work] = []
    var dueTimesNs: [Int64] = []
  }

  let scheduled = TestSignal()
  private let state = Mutex(State())

  var nowNs: Int64 { state.withLock { $0.nowNs } }
  var dueTimesNs: [Int64] { state.withLock { $0.dueTimesNs } }

  func run(afterNs delayNs: Int64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
    state.withLock { state in
      state.queue = queue
      state.works.append(Work(dueNs: state.nowNs + delayNs, run: work))
      state.dueTimesNs.append(state.nowNs + delayNs)
    }
    scheduled.signal()
  }

  func advance(byNs delayNs: Int64) {
    guard let queue = state.withLock({ $0.queue }) else { return }

    queue.async { [self] in step(byNs: delayNs) }
  }

  func step(byNs delayNs: Int64) {
    let due = state.withLock { state in
      state.nowNs += delayNs
      let now = state.nowNs
      defer { state.works.removeAll { $0.dueNs <= now } }
      return state.works.filter { $0.dueNs <= now }
    }
    for work in due { work.run() }
  }
}
