import Testing

@testable import ScreenSharingRigKit

struct RigImageAgeTests {
  @Test func summarisesPercentilesAndClears() throws {
    var ages = RigImageAge(capacity: 10)
    for ms in [30.0, 50, 40, 100, 45] { ages.record(ageSeconds: ms / 1000) }
    let taken = ages.take()
    let summary = try #require(taken)
    #expect(summary.count == 5)
    #expect(summary.p50Milliseconds == 45)
    #expect(summary.p95Milliseconds == 100)
    #expect(summary.maximumMilliseconds == 100)
    #expect(ages.take() == nil, "taking clears the interval")
  }

  @Test func boundedCapacityStillCountsDroppedSamples() throws {
    var ages = RigImageAge(capacity: 2)
    ages.record(ageSeconds: 0.010)
    ages.record(ageSeconds: 0.020)
    ages.record(ageSeconds: 0.900)
    ages.record(ageSeconds: .nan)
    let taken = ages.take()
    let summary = try #require(taken)
    #expect(summary.count == 3)
    #expect(summary.maximumMilliseconds == 20, "samples beyond capacity are counted, not stored")
  }
}
