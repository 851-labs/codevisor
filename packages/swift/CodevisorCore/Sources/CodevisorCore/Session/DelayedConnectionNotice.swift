import Foundation
import Observation

/// A connection problem the user is only told about once it has lasted.
/// Brief blips — a relay handoff, the app coming back from the background —
/// reconnect within `delay` and never show; a notice that does show stays up
/// for `minimumVisible`, so it never flashes in and out of the transcript.
@MainActor
@Observable
final class DelayedConnectionNotice {
  typealias Now = @MainActor @Sendable () -> ContinuousClock.Instant
  typealias Sleep = @MainActor @Sendable (_ interval: Duration) async throws -> Void

  private(set) var isVisible = false {
    didSet { if isVisible != oldValue { onVisibilityChange?(isVisible) } }
  }
  @ObservationIgnored var onVisibilityChange: ((Bool) -> Void)?
  @ObservationIgnored private var isActive = false
  @ObservationIgnored private var shownAt: ContinuousClock.Instant?
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private let delay: Duration
  @ObservationIgnored private let minimumVisible: Duration
  @ObservationIgnored private let now: Now
  @ObservationIgnored private let sleep: Sleep

  init(delay: Duration, minimumVisible: Duration = .seconds(1), now: @escaping Now, sleep: @escaping Sleep) {
    self.delay = delay
    self.minimumVisible = minimumVisible
    self.now = now
    self.sleep = sleep
  }

  /// Whether the problem is happening right now.
  func update(isActive active: Bool) {
    guard active != isActive else { return }
    isActive = active
    pending?.cancel()
    pending = nil
    if active {
      guard !isVisible else { return }
      schedule(after: delay) { $0.show() }
    } else if let shownAt {
      let remaining = minimumVisible - shownAt.duration(to: now())
      if remaining > .zero {
        schedule(after: remaining) { $0.hide() }
      } else {
        hide()
      }
    }
  }

  deinit {
    pending?.cancel()
  }

  private func show() {
    shownAt = now()
    isVisible = true
  }

  private func hide() {
    shownAt = nil
    isVisible = false
  }

  private func schedule(after interval: Duration, _ action: @escaping @MainActor (DelayedConnectionNotice) -> Void) {
    pending = Task { [weak self, sleep] in
      do {
        try await sleep(interval)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.pending = nil
      action(self)
    }
  }
}
