import Foundation
import Testing

@testable import CodevisorClient

struct ServerHarnessUsagePaceTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func window(used: Double, minutes: Double? = 300, resetsIn: TimeInterval?) -> ServerHarnessUsageWindow
  {
    ServerHarnessUsageWindow(
      id: "five-hour",
      label: "5-hour limit",
      usedPercent: used,
      durationMinutes: minutes,
      resetsAt: resetsIn.map { ServerDateCoding.string(from: now.addingTimeInterval($0)) }
    )
  }

  @Test("Using less than the even share leaves a reserve that lasts until the reset")
  func reserve() throws {
    let pace = try #require(Self.window(used: 10, resetsIn: 3 * 3_600).pace(now: Self.now))
    #expect(pace.expectedPercent == 40)
    #expect(pace.reservePercent == 30)
    #expect(pace.outlook == .lastsUntilReset)
  }

  @Test("Using more than the even share runs out before the reset, at the current rate")
  func deficit() throws {
    let pace = try #require(Self.window(used: 80, resetsIn: 3 * 3_600).pace(now: Self.now))
    #expect(pace.reservePercent == -40)
    #expect(pace.outlook == .runsOut(Self.now.addingTimeInterval(1_800)))
  }

  @Test("Nothing used yet lasts until the reset")
  func unused() throws {
    let pace = try #require(Self.window(used: 0, resetsIn: 3_600).pace(now: Self.now))
    #expect(pace.outlook == .lastsUntilReset)
  }

  @Test("No pace without timing, outside the window, or in its first few percent")
  func unavailable() {
    #expect(Self.window(used: 10, minutes: nil, resetsIn: 3_600).pace(now: Self.now) == nil)
    #expect(Self.window(used: 10, resetsIn: nil).pace(now: Self.now) == nil)
    #expect(Self.window(used: 10, resetsIn: -60).pace(now: Self.now) == nil)
    #expect(Self.window(used: 10, resetsIn: 6 * 3_600).pace(now: Self.now) == nil)
    #expect(Self.window(used: 10, resetsIn: 300 * 60 - 60).pace(now: Self.now) == nil)
  }
}
