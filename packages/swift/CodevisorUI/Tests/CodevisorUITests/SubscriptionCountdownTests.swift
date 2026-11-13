import Foundation
import Testing

@testable import CodevisorUI

struct SubscriptionCountdownTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let cases: [(remaining: TimeInterval, text: String)] = [
    (1_200, "In 20 mins"),
    (1_141, "In 20 mins"),
    (59, "In 1 min"),
    (3_600, "In 1 hr"),
    (4_800, "In 1 hr 20 mins"),
    (176_400, "In 2 days"),
    (0, "Now"),
    (-30, "Now"),
  ]

  @Test("A one-time reminder counts down in whole minutes, rounding up, then hours and days", arguments: cases)
  func countsDown(remaining: TimeInterval, text: String) {
    #expect(SubscriptionCountdown.text(until: Self.now.addingTimeInterval(remaining), now: Self.now) == text)
  }
}
