import ScreenSharing

enum EncodeLabCodec: String, Sendable, Codable {
  case hevc444
  case hevc
  case h264

  var video: ScreenSharingVideoCodec {
    switch self {
    case .hevc444: .hevc444
    case .hevc: .hevc
    case .h264: .h264
    }
  }
}
