import ScreenSharingBench

struct EncodeLabResult: Codable, Sendable {
  let scene: String
  let config: EncodeLabConfig
  var error: String?
  var frames = 0
  var tilesPerFrame = 0.0
  var chroma: String?
  var encodeMs: BenchDistribution?
  var firstTileMs: BenchDistribution?
  var prepareMs: BenchDistribution?
  var submitBlockMs: BenchDistribution?
  var lateSubmits = 0
  var repeatFrames = 0
  var dropped = 0
  var megabitsPerSecond = 0.0
  var frameKilobytes: BenchDistribution?
  var firstFrame: EncodeLabFrameCost?
  var refresh: EncodeLabFrameCost?
  var quality: EncodeLabQualitySummary?
  var decodeMs: BenchDistribution?
}
