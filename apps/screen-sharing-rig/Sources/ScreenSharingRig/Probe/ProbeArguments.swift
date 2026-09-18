import ScreenSharing

struct ProbeArguments {
  var values: [String: String] = [:]
  var flags = Set<String>()

  init(_ arguments: [String]) throws {
    let switches = [
      "--loopback", "--send", "--receive", "--list-displays", "--capabilities", "--check-quality", "--check-codecs",
      "--keep-front", "--render-on-arrival", "--standard-rate-control", "--capture-picker", "--unsynced-presentation",
      "--render-off-main",
      "--show-workload", "--no-lookahead", "--fixed-source-rate", "--copy-capture-surface", "--static-codec-rate",
      "--complete-each-frame", "--check-recovery", "--headless-recovery", "--drop-recovery-keyframe",
      "--idle-on-decoder-reset", "--headless", "--final-burst-signal", "--trace-boundary", "--capture-owned-window",
      "--record-owned-workload-times",
      "--prioritize-encoding-speed", "--desktop-pattern", "--user-initiated-activity",
      "--request-screen-recording", "--capture-picker-window", "--workload-window",
      "--record-workload-times",
      "--low-latency-playout",
      "--metal-display-link",
    ]
    let valued = [
      "--width", "--height", "--fps", "--bitrate", "--duration", "--display", "--offer", "--answer", "--report",
      "--check-host", "--workspace", "--pane", "--codec-case", "--synthetic-format", "--jitter-window-frames",
      "--playout-delay-min-ms", "--playout-delay-max-ms", "--delivery-audit-begin", "--delivery-audit-duration",
      "--rtc-event-log-begin", "--rtc-event-log-duration",
      "--sender-rtc-event-log-begin", "--sender-rtc-event-log-duration",
      "--capture-queue-depth", "--capture-interval-fps",
      "--codec",
      "--drawable-count",
      "--render-fps",
      "--viewer-display",
      "--capture-format",
      "--encoder-inflight",
      "--keyframe-interval",
      "--pause-source-after",
      "--pause-workload-after",
      "--idle-threshold-ms",
      "--idle-grace-ms",
      "--idle-grace-extensions",
      "--synthetic-gap-ms",
      "--sample-interval-seconds",
    ]
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard values[key] == nil, !flags.contains(key) else {
        throw ScreenSharingError.invalid("Repeated option: \(key)")
      }
      if switches.contains(key) {
        flags.insert(key)
      } else if valued.contains(key), index + 1 < arguments.count {
        index += 1
        values[key] = arguments[index]
      } else {
        throw ScreenSharingError.invalid("Unknown or incomplete option: \(key)\n\(ProbeOptions.usage)")
      }
      index += 1
    }
  }
}
