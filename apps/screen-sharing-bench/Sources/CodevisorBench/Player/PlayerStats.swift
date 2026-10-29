import Foundation
import Synchronization

final class PlayerStats: Sendable {
  struct Snapshot: Sendable {
    var updates = 0
    var versions = 0
    var missedRefreshes = 0
    var presentedOnGlass = 0
    var lastTick = 0
    var firstTarget: Double?
    var lastTarget: Double = 0

    var seconds: Double {
      lastTarget - (firstTarget ?? lastTarget)
    }
  }

  private let state = Mutex(Snapshot())

  var snapshot: Snapshot {
    state.withLock { $0 }
  }

  func recordUpdate(tick: Int, target: Double) {
    state.withLock { stats in
      if stats.updates > 0 { stats.missedRefreshes += max(0, tick - stats.lastTick - 1) }
      stats.updates += 1
      stats.lastTick = tick
      stats.firstTarget = stats.firstTarget ?? target
      stats.lastTarget = target
    }
  }

  func recordVersion() {
    state.withLock { $0.versions += 1 }
  }

  func recordPresented(at time: CFTimeInterval) {
    guard time > 0 else { return }

    state.withLock { $0.presentedOnGlass += 1 }
  }
}
