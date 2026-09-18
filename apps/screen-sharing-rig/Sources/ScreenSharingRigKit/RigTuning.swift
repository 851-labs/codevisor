import ScreenSharing
import ScreenSharingWebRTC
import Foundation

/// Optional engine knobs from `rig.json`'s `tuning` object. Field trials are process-global and
/// immutable, so every value here applies at process start on both ends; `rig tune` rewrites the
/// configs and restarts the agents, which is a fresh process in a few seconds.
public struct RigTuning: Equatable, Sendable {
  /// `WebRTC-ForcePlayoutDelay` bounds in milliseconds (receiver playout).
  public let playoutDelayMs: (min: Int, max: Int)?
  /// `WebRTC-JitterEstimatorConfig` frame-size window.
  public let jitterWindowFrames: Int?
  /// Viewer renderer: draw on frame arrival instead of the display link.
  public let renderOnArrival: Bool
  /// Viewer renderer: 2 or 3 drawables.
  public let maximumDrawableCount: Int
  /// Viewer renderer: acquire and encode off the main actor (needs `renderOnArrival`).
  public let offMainPreparation: Bool
  /// Host: ScreenCaptureKit minimum-frame-interval request, independent of the video rate.
  public let captureIntervalFPS: Int?
  /// Host encoder: nominal keyframe interval in seconds; nil keeps the product's 2 s.
  public let keyframeIntervalSeconds: Int?
  /// Host encoder: VideoToolbox standard rate control instead of the low-latency controller. Main444 needs it.
  public let standardRateControl: Bool
  /// Host encoder: frames admitted to VideoToolbox at once; nil keeps the product's 2.
  public let pendingFrames: Int?
  /// Host transport: estimator/sender cap in bps above the encoder's average bitrate; nil keeps one ceiling.
  public let transportCeilingBps: Int?
  /// Host encoder: ignore the transport's rate updates and hold the configured average bitrate, so a raised
  /// ceiling changes only how fast bytes may leave, not how many the encoder makes.
  public let staticCodecRate: Bool
  /// Host transport: `WebRTC-Video-Pacing factor` — the pacer's multiple of the target bitrate; nil keeps 2.5.
  public let pacingFactor: Double?

  public static let `default` = RigTuning(
    playoutDelayMs: nil, jitterWindowFrames: nil, renderOnArrival: false, maximumDrawableCount: 3,
    offMainPreparation: false, captureIntervalFPS: nil)

  /// The product's one diagnostic profile, expressed as rig tuning.
  public static let paced15Worker = RigTuning(
    playoutDelayMs: (1, 15), jitterWindowFrames: nil, renderOnArrival: true, maximumDrawableCount: 2,
    offMainPreparation: true, captureIntervalFPS: 120)

  public init(
    playoutDelayMs: (min: Int, max: Int)?, jitterWindowFrames: Int?, renderOnArrival: Bool,
    maximumDrawableCount: Int, offMainPreparation: Bool, captureIntervalFPS: Int?,
    keyframeIntervalSeconds: Int? = nil, standardRateControl: Bool = false, pendingFrames: Int? = nil,
    transportCeilingBps: Int? = nil, staticCodecRate: Bool = false, pacingFactor: Double? = nil
  ) {
    self.playoutDelayMs = playoutDelayMs
    self.jitterWindowFrames = jitterWindowFrames
    self.renderOnArrival = renderOnArrival
    self.maximumDrawableCount = maximumDrawableCount
    self.offMainPreparation = offMainPreparation
    self.captureIntervalFPS = captureIntervalFPS
    self.keyframeIntervalSeconds = keyframeIntervalSeconds
    self.standardRateControl = standardRateControl
    self.pendingFrames = pendingFrames
    self.transportCeilingBps = transportCeilingBps
    self.staticCodecRate = staticCodecRate
    self.pacingFactor = pacingFactor
  }

  public static func == (lhs: RigTuning, rhs: RigTuning) -> Bool {
    lhs.playoutDelayMs?.min == rhs.playoutDelayMs?.min && lhs.playoutDelayMs?.max == rhs.playoutDelayMs?.max
      && lhs.jitterWindowFrames == rhs.jitterWindowFrames && lhs.renderOnArrival == rhs.renderOnArrival
      && lhs.maximumDrawableCount == rhs.maximumDrawableCount && lhs.offMainPreparation == rhs.offMainPreparation
      && lhs.captureIntervalFPS == rhs.captureIntervalFPS
      && lhs.keyframeIntervalSeconds == rhs.keyframeIntervalSeconds
      && lhs.standardRateControl == rhs.standardRateControl && lhs.pendingFrames == rhs.pendingFrames
      && lhs.transportCeilingBps == rhs.transportCeilingBps && lhs.staticCodecRate == rhs.staticCodecRate
      && lhs.pacingFactor == rhs.pacingFactor
  }

  /// Parses the `tuning` object. `profile` sets a base the other keys override.
  public static func parse(_ object: [String: Any]) throws -> RigTuning {
    let known: Set<String> = [
      "profile", "playoutDelayMs", "jitterWindowFrames", "renderOnArrival", "drawables", "offMainPreparation",
      "captureIntervalFPS", "keyframeIntervalSeconds", "rateControl", "pendingFrames", "transportCeiling",
      "staticCodecRate", "pacingFactor",
    ]
    let unknown = Set(object.keys).subtracting(known).sorted()
    guard unknown.isEmpty else { throw ScreenSharingError.invalid("tuning has unknown keys: \(unknown)") }
    var base = RigTuning.default
    if let profile = object["profile"] {
      guard let name = profile as? String else { throw ScreenSharingError.invalid("tuning.profile must be a string") }
      guard name == ScreenSharingDiagnosticProfile.paced15WorkerName else {
        throw ScreenSharingError.invalid("tuning.profile must be \(ScreenSharingDiagnosticProfile.paced15WorkerName)")
      }
      base = .paced15Worker
    }
    // JSON `true`/`false` and the numbers 0/1 both bridge to Bool and NSNumber; only the CF type tells them apart.
    func isBoolean(_ value: Any) -> Bool { CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() }
    func integer(_ key: String) throws -> Int? {
      guard let value = object[key] else { return nil }
      guard let number = value as? NSNumber, !isBoolean(value), number.doubleValue == number.doubleValue.rounded()
      else { throw ScreenSharingError.invalid("tuning.\(key) must be an integer") }
      return number.intValue
    }
    func flag(_ key: String) throws -> Bool? {
      guard let value = object[key] else { return nil }
      guard isBoolean(value), let flag = value as? Bool else {
        throw ScreenSharingError.invalid("tuning.\(key) must be true or false")
      }
      return flag
    }
    var playout = base.playoutDelayMs
    if let value = object["playoutDelayMs"] {
      guard let pair = value as? [Any], pair.count == 2, let low = (pair[0] as? NSNumber)?.intValue,
        let high = (pair[1] as? NSNumber)?.intValue, (0...10_000).contains(low), low <= high, high <= 10_000
      else { throw ScreenSharingError.invalid("tuning.playoutDelayMs must be [min, max] milliseconds, min ≤ max") }
      playout = (low, high)
    }
    let jitter = try integer("jitterWindowFrames") ?? base.jitterWindowFrames
    if let jitter, !(2...600).contains(jitter) {
      throw ScreenSharingError.invalid("tuning.jitterWindowFrames must be 2...600")
    }
    let drawables = try integer("drawables") ?? base.maximumDrawableCount
    guard (2...3).contains(drawables) else { throw ScreenSharingError.invalid("tuning.drawables must be 2 or 3") }
    let capture = try integer("captureIntervalFPS") ?? base.captureIntervalFPS
    if let capture, !(1...240).contains(capture) {
      throw ScreenSharingError.invalid("tuning.captureIntervalFPS must be 1...240")
    }
    let renderOnArrival = try flag("renderOnArrival") ?? base.renderOnArrival
    let offMain = try flag("offMainPreparation") ?? base.offMainPreparation
    guard !offMain || renderOnArrival else {
      throw ScreenSharingError.invalid("tuning.offMainPreparation requires renderOnArrival")
    }
    let keyframe = try integer("keyframeIntervalSeconds") ?? base.keyframeIntervalSeconds
    if let keyframe, !(1...60).contains(keyframe) {
      throw ScreenSharingError.invalid("tuning.keyframeIntervalSeconds must be 1...60")
    }
    var standardRateControl = base.standardRateControl
    if let value = object["rateControl"] {
      guard let name = value as? String, ["lowLatency", "standard"].contains(name) else {
        throw ScreenSharingError.invalid("tuning.rateControl must be lowLatency or standard")
      }
      standardRateControl = name == "standard"
    }
    let pending = try integer("pendingFrames") ?? base.pendingFrames
    if let pending, !(1...8).contains(pending) {
      throw ScreenSharingError.invalid("tuning.pendingFrames must be 1...8")
    }
    let ceiling = try integer("transportCeiling") ?? base.transportCeilingBps
    if let ceiling, !(100_000...500_000_000).contains(ceiling) {
      throw ScreenSharingError.invalid("tuning.transportCeiling must be 100000...500000000 bps")
    }
    let staticRate = try flag("staticCodecRate") ?? base.staticCodecRate
    var pacing = base.pacingFactor
    if let value = object["pacingFactor"] {
      guard let number = value as? NSNumber, !isBoolean(value), (1.0...50.0).contains(number.doubleValue) else {
        throw ScreenSharingError.invalid("tuning.pacingFactor must be a number 1...50")
      }
      pacing = number.doubleValue
    }
    return RigTuning(
      playoutDelayMs: playout, jitterWindowFrames: jitter, renderOnArrival: renderOnArrival,
      maximumDrawableCount: drawables, offMainPreparation: offMain, captureIntervalFPS: capture,
      keyframeIntervalSeconds: keyframe, standardRateControl: standardRateControl, pendingFrames: pending,
      transportCeilingBps: ceiling, staticCodecRate: staticRate, pacingFactor: pacing)
  }

  /// The process-wide WebRTC trial selection these knobs require.
  public var fieldTrialSelection: ScreenSharingFieldTrials.Selection {
    .probeOptions(
      jitterWindowFrames: jitterWindowFrames, lowLatencyPlayout: false, playoutDelayBoundsMs: playoutDelayMs,
      pacingFactor: pacingFactor)
  }

  /// Short human label for status and the HUD; nil for the defaults.
  public var label: String? {
    var parts: [String] = []
    if let playoutDelayMs { parts.append("playout \(playoutDelayMs.min)/\(playoutDelayMs.max)") }
    if let jitterWindowFrames { parts.append("jitter window \(jitterWindowFrames)") }
    if renderOnArrival { parts.append(offMainPreparation ? "arrival+worker" : "arrival") }
    if maximumDrawableCount != 3 { parts.append("\(maximumDrawableCount) drawables") }
    if let captureIntervalFPS { parts.append("capture \(captureIntervalFPS)") }
    if let keyframeIntervalSeconds { parts.append("keyframe \(keyframeIntervalSeconds)s") }
    if standardRateControl { parts.append("standard rc") }
    if let pendingFrames { parts.append("pending \(pendingFrames)") }
    if let transportCeilingBps { parts.append("ceiling \(transportCeilingBps / 1_000_000) Mb") }
    if staticCodecRate { parts.append("static rate") }
    if let pacingFactor { parts.append("pacing ×\(pacingFactor)") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
