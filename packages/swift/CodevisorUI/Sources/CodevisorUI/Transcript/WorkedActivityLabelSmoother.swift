import ACPKit
import Foundation
import TranscriptKit

struct WorkedActivityLabelSmoother: Equatable {
  static let settleInterval: TimeInterval = 0.3
  static let refreshInterval: TimeInterval = 1.2

  private(set) var shown: WorkedSectionActivity?
  private var candidate: WorkedSectionActivity?
  private var candidateSince = Date.distantPast
  private var staleSince: Date?

  static func initial(_ activity: WorkedSectionActivity) -> WorkedSectionActivity {
    activity == .pending ? .step("Thinking") : activity
  }

  mutating func observe(_ next: WorkedSectionActivity, now: Date) {
    guard let shown else {
      shown = Self.initial(next)
      candidate = shown
      candidateSince = now
      return
    }
    if next != candidate {
      candidate = next
      candidateSince = now
    }
    if next == shown {
      staleSince = nil
    } else if next != .pending, staleSince == nil {
      staleSince = now
    }
    tick(now: now)
  }

  mutating func tick(now: Date) {
    guard let deadline, now >= deadline, let candidate else { return }
    shown = candidate
    staleSince = nil
  }

  var deadline: Date? {
    guard let candidate, candidate != .pending, candidate != shown else { return nil }
    let settle = candidateSince.addingTimeInterval(Self.settleInterval)
    guard let staleSince else { return settle }
    return min(settle, staleSince.addingTimeInterval(Self.refreshInterval))
  }
}
