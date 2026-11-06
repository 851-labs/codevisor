import Testing

@testable import ScreenSharingV2

struct ScreenSharingV2WindowedMinimumTests {
  @Test func theMinimumIsTheSmallestSampleNoOlderThanTheWindow() {
    var minimum = ScreenSharingV2WindowedMinimum(windowNs: 10)

    let values = [(50.0, 0), (20, 1), (30, 5), (40, 11), (60, 12)].map { minimum.observe($0.0, atNs: Int64($0.1)) }

    #expect(values == [50, 20, 20, 20, 30])
  }
}
