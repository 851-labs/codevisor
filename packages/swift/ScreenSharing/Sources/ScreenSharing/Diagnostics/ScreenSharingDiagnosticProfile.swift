import Foundation

/// One explicit, immutable, DEFAULT-OFF experimental profile for the product panes.
///
/// It is enabled only by `CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE=paced15-worker` in the app process
/// environment. An absent or empty variable means OFF. A non-empty unknown value is a configuration FAILURE: it never
/// silently selects the candidate.
///
/// The name is deliberately "diagnostic". The profile selects receiver playout bounds, a capture-interval request and
/// the renderer preparation path. It selects NO network route, interface or candidate policy, and says nothing about
/// which physical path a pane negotiates or uses. It is unevaluated over relay, and it is NOT inert for a pane that
/// negotiates relay or changes path later.
public struct ScreenSharingDiagnosticProfile: Equatable, Sendable {
  public static let environmentKey = "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE"
  public static let paced15WorkerName = "paced15-worker"

  public let name: String
  /// Receiver playout bounds forwarded as the pinned M152 `WebRTC-ForcePlayoutDelay` trial. A positive minimum keeps
  /// the paced branch of the pinned `timing.cc`; 15 ms is a narrower cap than the 35 ms diagnostic, and neither is a
  /// latency guarantee nor an explanation of observed update gaps.
  public let playoutDelayMinMs: Int
  public let playoutDelayMaxMs: Int
  /// SCK minimum-frame-interval request, applied ONLY at adaptive level 0; lower levels request the video rate.
  public let captureIntervalFPSAtLevel0: Int
  public let renderOnArrival: Bool
  public let maximumDrawableCount: Int
  public let offMainPreparation: Bool

  /// The one candidate: paced 1/15 playout, capture request 120 at level 0 only, synchronized arrival rendering with
  /// two drawables, and the existing off-main preparation path. No unsynced option, codec/GOP/bitrate/pacer change,
  /// persisted preference or UI control belongs to it.
  public static let paced15Worker = ScreenSharingDiagnosticProfile(
    name: paced15WorkerName, playoutDelayMinMs: 1, playoutDelayMaxMs: 15, captureIntervalFPSAtLevel0: 120,
    renderOnArrival: true, maximumDrawableCount: 2, offMainPreparation: true)

  /// The profile for THIS process, parsed exactly once — including a configuration failure, which is replayed to every
  /// caller instead of being re-derived per connection. The environment is immutable for a running process, so reading
  /// it repeatedly could only produce inconsistent answers between roles or connections.
  private static let processResult: Result<ScreenSharingDiagnosticProfile?, any Error> = Result {
    try resolve(environment: ProcessInfo.processInfo.environment)
  }

  /// The cached process profile; throws the same configuration failure every time when the variable is malformed.
  public static func process() throws -> ScreenSharingDiagnosticProfile? { try processResult.get() }

  /// Pure parsing, kept separate so it is testable without touching the process environment.
  /// Returns nil when the profile is OFF (variable absent or empty), the profile when it names a known one, and throws
  /// for any other non-empty value. Whitespace is not trimmed: an unknown spelling is a failure, not a near-match.
  public static func resolve(environment: [String: String]) throws -> ScreenSharingDiagnosticProfile? {
    guard let raw = environment[environmentKey], !raw.isEmpty else { return nil }
    guard raw == paced15WorkerName else {
      throw ScreenSharingError.invalid(
        "Unknown \(environmentKey) value \"\(raw)\". Use \"\(paced15WorkerName)\" or unset the variable.")
    }
    return paced15Worker
  }

  /// The capture-interval request for one adaptive level: the override at level 0, nil (= the video rate) below it.
  public func captureIntervalFPS(adaptiveLevel: Int) -> Int? {
    adaptiveLevel == 0 ? captureIntervalFPSAtLevel0 : nil
  }

  /// The exact native trial string this profile installs — the same spelling the probe uses.
  public var playoutExperimentLabel: String {
    "WebRTC-ForcePlayoutDelay min_ms:\(playoutDelayMinMs),max_ms:\(playoutDelayMaxMs)"
  }

  public var fieldTrials: [String: String] {
    ["WebRTC-ForcePlayoutDelay": "min_ms:\(playoutDelayMinMs),max_ms:\(playoutDelayMaxMs)"]
  }

}
