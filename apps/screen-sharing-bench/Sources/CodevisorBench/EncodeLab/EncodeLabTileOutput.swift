import CoreMedia

struct EncodeLabTileOutput: @unchecked Sendable {
  let frame: Int
  let tile: Int
  let submitNs: Int64
  let outputNs: Int64
  let bytes: Int
  let keyframe: Bool
  let refresh: Bool
  let sample: CMSampleBuffer?

  var dropped: Bool { sample == nil }
}
