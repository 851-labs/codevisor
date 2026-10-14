#if os(macOS)
  import Foundation
  import ScreenSharingWebRTC

  func installPlayoutOverride(environment: [String: String] = ProcessInfo.processInfo.environment) {
    guard let raw = environment["RIG_PLAYOUT_DELAY_MS"], !raw.isEmpty else { return }
    var trials = ScreenSharingFieldTrials.Selection.product.trials
    if raw == "off" {
      trials.removeValue(forKey: "WebRTC-ForcePlayoutDelay")
    } else {
      let bounds = raw.split(separator: ",").compactMap { Int($0) }
      guard bounds.count == 2 else {
        FileHandle.standardError.write(Data("RIG_PLAYOUT_DELAY_MS must be min,max or off\n".utf8))
        return
      }
      trials["WebRTC-ForcePlayoutDelay"] = "min_ms:\(bounds[0]),max_ms:\(bounds[1])"
    }
    _ = try? ScreenSharingFieldTrials.process.install(.init(name: "rig playout \(raw)", trials: trials))
  }
#endif
