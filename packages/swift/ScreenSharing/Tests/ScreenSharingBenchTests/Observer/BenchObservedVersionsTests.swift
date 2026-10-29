import ScreenSharingBench
import Testing

struct BenchObservedVersionsTests {
  @Test func eachVersionReachesGlassAtTheFirstFrameShowingItAndUnreadableFramesAreCounted() {
    let versions = BenchObservedVersions([
      BenchObservation(ptsNs: 100_000_000, callbackNs: 101_000_000, reading: .version(1)),
      BenchObservation(ptsNs: 116_666_667, callbackNs: 117_000_000, reading: .version(1)),
      BenchObservation(ptsNs: 133_333_333, callbackNs: 134_000_000, reading: .checksumMismatch),
      BenchObservation(ptsNs: 150_000_000, callbackNs: 151_000_000, reading: .ambiguousBlock(3)),
      BenchObservation(ptsNs: 166_666_667, callbackNs: 167_000_000, reading: .version(3)),
    ])

    #expect(versions.firstPtsNs == [1: 100_000_000, 3: 166_666_667])
    #expect(versions.frames == 5)
    #expect(versions.unreadableFrames == 2)
    #expect(versions.unreadableFraction == 0.4)
  }

  @Test func delaysCoverOnlyVersionsThatHaveAStartTime() {
    let versions = BenchObservedVersions([
      BenchObservation(ptsNs: 100_000_000, callbackNs: 0, reading: .version(1)),
      BenchObservation(ptsNs: 150_000_000, callbackNs: 0, reading: .version(3)),
    ])

    #expect(versions.delaysMs(since: [1: 75_000_000, 2: 90_000_000, 3: 150_000_000]) == [25, 0])
  }
}
