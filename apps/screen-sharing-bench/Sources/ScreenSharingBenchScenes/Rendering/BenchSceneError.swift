public enum BenchSceneError: Error, Equatable {
  case metalUnavailable
  case textureUnavailable
  case bitmapUnavailable
  case encoderUnavailable
  case versionOutOfRange(Int)
  case pixelBufferUnavailable(Int32)
}
