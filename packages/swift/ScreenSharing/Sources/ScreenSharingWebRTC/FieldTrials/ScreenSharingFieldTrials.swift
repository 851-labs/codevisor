import Foundation
import WebRTC
import ScreenSharing

/// The single process boundary for WebRTC field-trial initialization.
///
/// M152 exposes these experiments through PROCESS-WIDE trials that must be installed before any RTC object exists.
/// Pinned source fact (`sdk/objc/api/peerconnection/RTCFieldTrials.mm` at 6f37672d): `RTCInitFieldTrialDictionary`
/// flattens the dictionary into a C string and calls `webrtc::DeprecatedGlobalFieldTrials::Set`. It returns `void`,
/// signals no failure, and a later call simply overwrites the global string — objects already built keep the value
/// they read. Replacement is therefore never safe, and this type refuses it rather than relying on the native call:
///
/// * installation is SINGLE-FLIGHT and readiness is published only after the native apply has RETURNED — a caller that
///   arrives while another thread is applying waits, so no one can reach a factory on the strength of a selection that
///   has not been applied yet;
/// * the first applied selection fixes the process, including the default (empty) one — a later non-empty request
///   cannot silently replace it, it fails;
/// * a request whose TRIAL MAP equals what is installed is idempotent regardless of its provenance name, and the first
///   installer's provenance is preserved; names never create a false native conflict;
/// * a request whose trial map differs throws BEFORE any peer, factory or codec is created.
///
/// What it does NOT do: it cannot detect WebRTC calls made through paths that bypass it. Every entry point known in
/// this repository is wired through `process` (peer construction, the probe's option-derived trials, the product host
/// and viewer, and the bare-factory test helper); that is a wiring guarantee, not runtime interception of arbitrary
/// third-party RTC use.
///
/// Contract for the apply closure: it must not re-enter this instance (the real one calls
/// `RTCInitFieldTrialDictionary` and returns).
public final class ScreenSharingFieldTrials: @unchecked Sendable {
  public struct Selection: Equatable, Sendable {
    /// Human-readable provenance of the selection ("default" for the empty one). Provenance is descriptive only: it
    /// never takes part in conflict detection.
    public let name: String
    public let trials: [String: String]
    public init(name: String, trials: [String: String]) { self.name = name; self.trials = trials }
    public static let `default` = Selection(name: "default", trials: [:])
    /// The exact native playout string, when this selection installs one.
    public var playoutExperimentLabel: String? {
      trials["WebRTC-ForcePlayoutDelay"].map { "WebRTC-ForcePlayoutDelay \($0)" }
    }
    /// Two selections are compatible when they ask the native library for the SAME dictionary.
    public func installs(_ other: Selection) -> Bool { trials == other.trials }

    /// The selection the standalone probe derives from its options. It lives here, beside the boundary that installs
    /// it, so the probe's real path is covered by the library tests. Every existing combination is preserved:
    /// * `jitterWindowFrames` adds the jitter-estimator trial;
    /// * `lowLatencyPlayout` selects `min_ms:0,max_ms:0` (pinned M152 rtp_video_stream_receiver2.cc and timing.cc:
    ///   zero minimum/maximum selects ASAP rendering — not a latency guarantee);
    /// * `playoutDelayBoundsMs` selects those exact bounds (pinned timing.cc uses ASAP only for min 0 and max <= 500,
    ///   so a positive minimum keeps paced rendering — an experiment, not a guarantee).
    /// The two playout options are mutually exclusive at parse time, so their ordering here is unobservable.
    /// * `pacingFactor` sets `WebRTC-Video-Pacing factor:` (pinned video_send_stream_impl.cc: the pacer sends at this
    ///   multiple of the target bitrate; the default is 2.5), so a keyframe can leave faster than the average rate.
    public static func probeOptions(
      jitterWindowFrames: Int?, lowLatencyPlayout: Bool, playoutDelayBoundsMs: (min: Int, max: Int)?,
      pacingFactor: Double? = nil
    ) -> Selection {
      var trials: [String: String] = [:]
      if let window = jitterWindowFrames {
        trials["WebRTC-JitterEstimatorConfig"] = "max_frame_size_percentile:0.95,frame_size_window:\(window)"
      }
      if lowLatencyPlayout { trials["WebRTC-ForcePlayoutDelay"] = "min_ms:0,max_ms:0" }
      if let bounds = playoutDelayBoundsMs {
        trials["WebRTC-ForcePlayoutDelay"] = "min_ms:\(bounds.min),max_ms:\(bounds.max)"
      }
      if let pacingFactor { trials["WebRTC-Video-Pacing"] = "factor:\(pacingFactor)" }
      return Selection(name: trials.isEmpty ? "default" : "probe options", trials: trials)
    }
  }

  private enum State {
    case none
    /// A thread is inside the native apply. Readiness is deliberately NOT published in this state.
    case applying
    case installed(Selection)
  }

  /// Pure seam: the real process installs the native dictionary, tests inject a recorder and never mutate the
  /// process-global trials.
  private let apply: @Sendable ([String: String]) -> Void
  private let condition = NSCondition()
  private var state: State = .none
  /// Internal observer fired immediately before a caller blocks on the apply in progress. It exists so a test can
  /// acknowledge that a second caller actually REACHED the waiting boundary before the apply is released; production
  /// never sets it.
  var onWaitingForApply: (@Sendable () -> Void)?

  public init(apply: @escaping @Sendable ([String: String]) -> Void) { self.apply = apply }

  /// The real production boundary. The native call is skipped for an empty dictionary — installing "default" only
  /// fixes this process's selection, exactly as the probe behaved before this type existed.
  public static let process = ScreenSharingFieldTrials(apply: { trials in
    if !trials.isEmpty { RTCInitFieldTrialDictionary(trials) }
  })

  /// The selection in force, or nil while nothing has been applied yet. A selection appears here only once its native
  /// apply has returned.
  public var installed: Selection? {
    condition.lock(); defer { condition.unlock() }
    if case .installed(let selection) = state { return selection }
    return nil
  }

  /// Installs `selection` if nothing is installed yet, waits if another thread is applying, and returns the selection
  /// now in force. Throws when a selection with a DIFFERENT trial map is already installed: trials are
  /// process-immutable in this design, so the caller must never be told that its request is active when it is not.
  @discardableResult
  public func install(_ selection: Selection) throws -> Selection {
    // Apply-or-wait first, then judge: the returned value is always a selection that HAS been applied.
    let inForce = applyOrWaitForFirst(selection)
    guard inForce.installs(selection) else {
      throw ScreenSharingError.invalid(
        "WebRTC field trials are already initialized for \"\(inForce.name)\" in this process and cannot be "
          + "replaced with \"\(selection.name)\". Quit and start a fresh app process to change the selection.")
    }
    return inForce
  }

  /// Pins the default selection when nothing has been applied yet, and returns whatever is in force. Used by peer
  /// construction so a peer built without a profile can never be overtaken by a later profile request. It cannot fail
  /// and it never invents a result: the value returned is the selection that was actually applied in this process.
  @discardableResult
  public func ensureInstalled() -> Selection { applyOrWaitForFirst(.default) }

  /// Installs the selection required by `profile` (or the default when the profile is OFF) and returns what is in
  /// force. A conflict throws here, before any peer exists.
  @discardableResult
  public func install(profile: ScreenSharingDiagnosticProfile?) throws -> Selection {
    try install(profile?.trialSelection ?? .default)
  }

  /// Applies `requested` when this process has applied nothing yet, waits when another thread is mid-apply, and in
  /// every case returns the selection that has ACTUALLY been applied. Never throws: the native call is `void` and
  /// reports no failure, so there is nothing here to fail on and nothing to invent.
  private func applyOrWaitForFirst(_ requested: Selection) -> Selection {
    condition.lock()
    while true {
      switch state {
      case .none:
        // Single flight: this thread owns the apply, and readiness stays unpublished until it returns.
        state = .applying
        condition.unlock()
        apply(requested.trials)
        condition.lock()
        state = .installed(requested)
        condition.broadcast()
        condition.unlock()
        return requested
      case .applying:
        // Another thread is mid-apply; wait for it rather than proceeding on an unapplied selection.
        let observer = onWaitingForApply
        if let observer {
          condition.unlock()
          observer()
          condition.lock()
          // State may have advanced while the observer ran; re-evaluate rather than waiting on a finished apply.
          if case .applying = state {} else { continue }
        }
        condition.wait()
      case .installed(let existing):
        // First provenance wins; an identical map asked for under another name is simply already satisfied.
        condition.unlock()
        return existing
      }
    }
  }
}
