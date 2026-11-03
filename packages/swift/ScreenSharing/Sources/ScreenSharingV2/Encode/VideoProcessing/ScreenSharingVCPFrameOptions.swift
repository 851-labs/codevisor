import CoreFoundation
import VideoToolbox

struct ScreenSharingVCPFrameOptions {
  let keys: ScreenSharingVCPKeys
  let refresh: ScreenSharingTileRefresh?
  let acknowledged: [UInt64]
  let feedback: ScreenSharingVCPNetworkFeedback?

  var dictionary: CFDictionary? {
    var options: [CFString: Any] = [:]
    if !acknowledged.isEmpty { options[keys.acknowledgedTokens] = acknowledged.map { Int(truncatingIfNeeded: $0) } }
    if let refreshKey { options[refreshKey] = true }
    if let feedback { add(feedback, to: &options) }
    return options.isEmpty ? nil : options as CFDictionary
  }

  private var refreshKey: CFString? {
    switch refresh {
    case .keyframe: kVTEncodeFrameOptionKey_ForceKeyFrame
    case .longTermReference: kVTEncodeFrameOptionKey_ForceLTRRefresh
    case nil: nil
    }
  }

  private func add(_ feedback: ScreenSharingVCPNetworkFeedback, to options: inout [CFString: Any]) {
    if let key = keys.packetErrorRate { options[key] = feedback.packetErrorRate }
    if let key = keys.roundTripDelay { options[key] = feedback.roundTripDelayMs }
    if let key = keys.transmissionBitRate { options[key] = feedback.transmissionBitsPerSecond }
  }
}
