import Foundation

@MainActor
public final class DeferredPaneFocus {
  public typealias Schedule = (@escaping @MainActor () -> Void) -> Void

  private struct Request {
    let generation: UInt64
    let isCurrent: () -> Bool
    let focus: () -> Bool
  }

  private static var attemptsNow = false

  private let schedule: Schedule
  private var generation: UInt64 = 0
  private var pending: Request?

  public static func attemptingNow<Result>(_ body: () throws -> Result) rethrows -> Result {
    let previous = attemptsNow
    attemptsNow = true
    defer { attemptsNow = previous }
    return try body()
  }

  public init(schedule: @escaping Schedule = { action in DispatchQueue.main.async { action() } }) {
    self.schedule = schedule
  }

  public func request(isCurrent: @escaping () -> Bool, focus: @escaping () -> Bool) {
    generation &+= 1
    let request = Request(generation: generation, isCurrent: isCurrent, focus: focus)
    pending = request
    if Self.attemptsNow, request.isCurrent() {
      _ = request.focus()
      guard pending?.generation == request.generation else { return }
    }
    retry()
  }

  public func retry() {
    guard let request = pending else { return }
    schedule { [weak self] in
      guard let self, self.pending?.generation == request.generation else { return }
      _ = self.settle(request)
    }
  }

  private func settle(_ request: Request) -> Bool {
    guard request.isCurrent() else {
      pending = nil
      return true
    }
    let focused = request.focus()
    guard pending?.generation == request.generation else { return true }
    if focused { pending = nil }
    return focused
  }

  public func cancel() {
    pending = nil
  }
}
