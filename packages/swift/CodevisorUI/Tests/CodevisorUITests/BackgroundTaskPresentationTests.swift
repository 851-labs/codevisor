import CodevisorUI
import Foundation
import Testing

@Suite("Background task presentation")
struct BackgroundTaskPresentationTests {
  private let start = Date(timeIntervalSinceReferenceDate: 0)

  private static let cases: [(TimeInterval, String)] = [
    (-5, "0s"), (59.9, "59s"), (60, "1m"), (3599, "59m"), (3600, "1h"), (3600 + 5 * 60, "1h 5m"),
  ]

  @Test("Elapsed time is compact", arguments: cases)
  func elapsed(seconds: TimeInterval, text: String) {
    #expect(BackgroundTaskPresentation.elapsed(from: start, to: start.addingTimeInterval(seconds)) == text)
  }
}
