import Foundation
@testable import CodevisorCore

@MainActor
final class AdvancingServerUpdateScheduler {
  private let start = ContinuousClock.now
  private(set) var elapsed: Duration = .zero
  private(set) var requestedIntervals: [Duration] = []
  var onSleep: () -> Void = {}

  var scheduler: ServerUpdateScheduler {
    ServerUpdateScheduler(
      now: { self.start + self.elapsed },
      sleep: { interval in
        try Task.checkCancellation()
        self.requestedIntervals.append(interval)
        self.onSleep()
        self.advance(by: interval)
      }
    )
  }

  func advance(by duration: Duration) {
    elapsed += duration
  }
}
