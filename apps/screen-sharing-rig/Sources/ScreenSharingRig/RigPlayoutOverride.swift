#if os(macOS)
  import Foundation
  import ScreenSharingWebRTC

  /// `RIG_PLAYOUT_DELAY_MS=min,max` (or `off` for WebRTC's own adaptive buffer): the rig's viewer
  /// runs the product's trials with these playout bounds instead of 15…80 ms, to measure what the
  /// viewer's jitter buffer costs on a given path. Installed before any peer exists, so the product
  /// viewer code, which installs the product selection, keeps this one (the first applied wins).
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
