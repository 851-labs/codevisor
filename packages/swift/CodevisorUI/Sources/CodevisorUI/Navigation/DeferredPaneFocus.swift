import Foundation

/// Focus follows selection and native attachment. A pane that is still
/// loading parks its request until attachment, without polling or holding
/// up navigation. Every attempt rechecks the current destination.
@MainActor
public final class DeferredPaneFocus {
  public typealias Schedule = (@escaping @MainActor () -> Void) -> Void

  private struct Request {
    let generation: UInt64
    let isCurrent: () -> Bool
    let focus: () -> Bool
  }

  private let schedule: Schedule
  private var generation: UInt64 = 0
  private var pending: Request?

  public init(schedule: @escaping Schedule = { action in DispatchQueue.main.async { action() } }) {
    self.schedule = schedule
  }

  /// Returning false from `focus` means the native target has not attached
  /// yet. Its attachment callback calls `retry`; no timer keeps it alive.
  public func request(isCurrent: @escaping () -> Bool, focus: @escaping () -> Bool) {
    generation &+= 1
    pending = Request(generation: generation, isCurrent: isCurrent, focus: focus)
    retry()
  }

  public func retry() {
    guard let request = pending else { return }
    schedule { [weak self] in
      guard let self, self.pending?.generation == request.generation else { return }
      guard request.isCurrent() else {
        self.pending = nil
        return
      }
      if request.focus(), self.pending?.generation == request.generation {
        self.pending = nil
      }
    }
  }

  public func cancel() {
    pending = nil
  }
}
