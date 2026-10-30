import VideoToolbox

enum EncodeLabPreset {
  static func key(named name: String) -> CFString {
    switch name {
    case "vc": kVTCompressionPreset_VideoConferencing
    case "speed": kVTCompressionPreset_HighSpeed
    case "balanced": kVTCompressionPreset_Balanced
    case "quality": kVTCompressionPreset_HighQuality
    default: name as CFString
    }
  }
}
