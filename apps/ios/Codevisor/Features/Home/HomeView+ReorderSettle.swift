import CodevisorCore
import CodevisorUI
import SwiftUI

/// The home list's order-freeze machinery: the touch/hover interaction hold,
/// the reactive settle hold that coalesces bursts of automatic reorders, and
/// the pre-emptive foreground hold that absorbs a catch-up replay into one
/// animated reflow.
extension HomeView {
  /// Pacing for a settle hold: which quiet delay and budget it runs under.
  enum ReorderSettleProfile {
    case reactive
    case foreground

    var quietDelay: TimeInterval {
      switch self {
      case .reactive: ReorderSettle.quietDelay
      case .foreground: ReorderSettle.foregroundQuietDelay
      }
    }

    var maxHold: TimeInterval {
      switch self {
      case .reactive: ReorderSettle.maxHold
      case .foreground: ReorderSettle.foregroundMaxHold
      }
    }
  }

  func setAutomaticOrderDeferred(_ isDeferred: Bool) {
    if isDeferred {
      // The touch/hover hold takes over any in-flight settle hold (the
      // lock is first-snapshot-wins, so the frozen order is preserved)
      // and owns it until the interaction ends.
      cancelReorderSettleHold()
      deferredSessionOrder.lock(to: visibleSessions.map(\.id))
    } else {
      releaseDeferredOrder(animated: true)
    }
  }

  /// Coalesces bursts of automatic reorders. The first change of a burst
  /// commits immediately — it has already rendered by the time this runs —
  /// then the order freezes until the sort has been quiet for
  /// `ReorderSettle.quietDelay`, capped at `ReorderSettle.maxHold` under
  /// sustained churn. While the user is touching or hovering the list the
  /// interaction hold owns the lock instead, and its end releases
  /// immediately as before.
  func scheduleReorderSettleHold() {
    guard order != .none, !isPointerInsideSidebar, !isTouchingSidebar else { return }
    if !deferredSessionOrder.isLocked {
      deferredSessionOrder.lock(to: visibleSessions.map(\.id))
      reorderSettleHoldStart = Date()
      reorderSettleProfile = .reactive
    }
    scheduleReorderSettleRelease()
  }

  /// Pre-emptively freezes row order for the foreground catch-up burst.
  /// Unlike the reactive settle hold, the burst's first change must not
  /// commit — it is the start of a replay, not an isolated reorder. If
  /// nothing changed while backgrounded, the hold releases after one
  /// (foreground-sized) quiet delay as a no-op reflow.
  func beginForegroundSettleHold() {
    guard order != .none, !isPointerInsideSidebar, !isTouchingSidebar else { return }
    cancelReorderSettleHold()
    deferredSessionOrder.lock(to: visibleSessions.map(\.id))
    reorderSettleHoldStart = Date()
    reorderSettleProfile = .foreground
    scheduleReorderSettleRelease()
  }

  /// (Re)arms the release: quiet delay after the latest change, bounded by
  /// the active hold's budget.
  private func scheduleReorderSettleRelease() {
    let holdStart = reorderSettleHoldStart ?? Date()
    let profile = reorderSettleProfile
    reorderSettleTask?.cancel()
    reorderSettleTask = Task {
      try? await Task.sleep(
        for: .seconds(
          ReorderSettle.delay(
            holdStart: holdStart,
            quietDelay: profile.quietDelay,
            maxHold: profile.maxHold
          )
        )
      )
      guard !Task.isCancelled else { return }
      reorderSettleTask = nil
      reorderSettleHoldStart = nil
      releaseDeferredOrder(animated: true)
    }
  }

  private func cancelReorderSettleHold() {
    reorderSettleTask?.cancel()
    reorderSettleTask = nil
    reorderSettleHoldStart = nil
    reorderSettleProfile = .reactive
  }

  func releaseDeferredOrder(animated: Bool) {
    cancelReorderSettleHold()
    guard deferredSessionOrder.isLocked else { return }
    if animated {
      withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
        deferredSessionOrder.unlock()
      }
    } else {
      deferredSessionOrder.unlock()
    }
  }
}
