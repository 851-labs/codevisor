import ScreenSharingBench

struct LoopbackFrameLine: Encodable {
  let scene: String
  let network: String
  let repetition: Int
  let version: Int
  let clock = BenchObserverHeader.continuousClock
  let timestamps: BenchFrameTimestamps
}
