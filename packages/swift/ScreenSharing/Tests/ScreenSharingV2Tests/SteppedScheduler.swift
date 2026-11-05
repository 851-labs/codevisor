import Dispatch
import Synchronization

@testable import ScreenSharingV2

final class SteppedScheduler: ScreenSharingV2Scheduler {
  private struct Work {
    let dueNs: Int64
    let run: @Sendable () -> Void
  }

  private struct State {
    var nowNs: Int64 = 1_000_000_000
    var works: [Work] = []
  }

  private let state = Mutex(State())

  var nowNs: Int64 { state.withLock { $0.nowNs } }

  func run(afterNs delayNs: Int64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
    state.withLock { state in
      let dueNs = state.nowNs + delayNs
      state.works.append(Work(dueNs: dueNs, run: work))
    }
  }

  func advance(byNs delayNs: Int64) {
    let due = state.withLock { state in
      state.nowNs += delayNs
      let nowNs = state.nowNs
      defer { state.works.removeAll { $0.dueNs <= nowNs } }
      return state.works.filter { $0.dueNs <= nowNs }
    }
    for work in due { work.run() }
  }
}
