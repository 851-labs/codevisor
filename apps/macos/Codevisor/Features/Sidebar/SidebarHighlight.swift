import AppKit
import Observation

@Observable
final class SidebarHighlight {
  private struct PendingTarget {
    let target: SidebarSelection?
  }

  private static let paintDelay: Duration = .milliseconds(16)
  private static let keyRepeatGapAllowance = 2.0
  private static let longestKeyRepeatWait: TimeInterval = 0.25

  private var pending: PendingTarget?
  @ObservationIgnored private var commit: (() -> Void)?
  @ObservationIgnored private var commitTask: Task<Void, Never>?

  func target(over committed: SidebarSelection?) -> SidebarSelection? {
    guard let pending else { return committed }
    return pending.target
  }

  func show(_ target: SidebarSelection?, then commit: @escaping () -> Void) {
    pending = PendingTarget(target: target)
    self.commit = commit
    scheduleCommit(after: Self.commitDelay(after: NSApp.currentEvent))
  }

  func discard() {
    commitTask?.cancel()
    commitTask = nil
    commit = nil
    pending = nil
  }

  private func scheduleCommit(after delay: Duration) {
    commitTask?.cancel()
    commitTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  private func flush() {
    let commit = commit
    discard()
    commit?()
  }

  private static func commitDelay(after event: NSEvent?) -> Duration {
    guard let event, isKeyRepeat(event) else { return paintDelay }
    return .seconds(min(NSEvent.keyRepeatInterval * keyRepeatGapAllowance, longestKeyRepeatWait))
  }

  private static func isKeyRepeat(_ event: NSEvent) -> Bool {
    event.type == .keyDown && event.isARepeat
  }
}
