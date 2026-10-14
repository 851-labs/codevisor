import Foundation

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
