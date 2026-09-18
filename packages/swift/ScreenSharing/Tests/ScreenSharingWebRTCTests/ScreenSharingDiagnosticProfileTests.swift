import Foundation
import Testing

@testable import ScreenSharing
@testable import ScreenSharingWebRTC

/// Stage 3t: the default-OFF experimental product profile and the single WebRTC initialization boundary.
/// Every test owns its own `ScreenSharingFieldTrials` instance with an injected apply closure: the real
/// process-global trials are never touched here, and no test depends on another's order.
@Suite struct ScreenSharingDiagnosticProfileTests {

  // MARK: profile resolution

  @Test func theProfileIsOffUnlessTheVariableNamesItExactly() throws {
    #expect(try ScreenSharingDiagnosticProfile.resolve(environment: [:]) == nil)
    #expect(try ScreenSharingDiagnosticProfile.resolve(environment: ["OTHER": "paced15-worker"]) == nil)
    #expect(
      try ScreenSharingDiagnosticProfile.resolve(
        environment: [ScreenSharingDiagnosticProfile.environmentKey: ""]) == nil)
    let on = try ScreenSharingDiagnosticProfile.resolve(
      environment: [ScreenSharingDiagnosticProfile.environmentKey: "paced15-worker"])
    #expect(on == ScreenSharingDiagnosticProfile.paced15Worker)
  }

  @Test func anUnknownValueFailsInsteadOfSelectingTheCandidate() {
    for raw in [
      "paced15", "paced15-worker ", " paced15-worker", "Paced15-Worker", "PACED15-WORKER", "1", "true",
      "off", "default", "paced35-worker",
    ] {
      #expect(throws: ScreenSharingError.self) {
        try ScreenSharingDiagnosticProfile.resolve(
          environment: [ScreenSharingDiagnosticProfile.environmentKey: raw])
      }
    }
  }

  @Test func theProfileMapIsExactAndLevelAware() {
    let profile = ScreenSharingDiagnosticProfile.paced15Worker
    #expect(profile.name == "paced15-worker")
    #expect(profile.fieldTrials == ["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:15"])
    #expect(profile.playoutExperimentLabel == "WebRTC-ForcePlayoutDelay min_ms:1,max_ms:15")
    #expect(profile.trialSelection.playoutExperimentLabel == profile.playoutExperimentLabel)
    #expect((profile.renderOnArrival, profile.maximumDrawableCount, profile.offMainPreparation) == (true, 2, true))
    // The capture request is the override only at level 0; every lower level requests the video rate.
    #expect(profile.captureIntervalFPS(adaptiveLevel: 0) == 120)
    for level in 1...3 { #expect(profile.captureIntervalFPS(adaptiveLevel: level) == nil) }
  }

  @Test func theLevelAwareRequestStaysValidAsAdaptationLowersTheVideoRate() throws {
    let profile = ScreenSharingDiagnosticProfile.paced15Worker
    // Level 0: 60 fps video with the 120 override is a valid request.
    let atZero = try ScreenSharingCaptureIntervalRequest(
      videoFramesPerSecond: 60, overrideFramesPerSecond: profile.captureIntervalFPS(adaptiveLevel: 0))
    #expect(atZero.requestedFramesPerSecond == 120 && atZero.isOverride)
    // Lower levels: nil keeps the video rate. A 120 request would still VALIDATE at 30 fps (the rule is only
    // "at least the video rate, at most 120"), so dropping it below level 0 is this profile's deliberate choice —
    // asking for four times the video rate while adaptation is shedding load is not what the profile means.
    for (level, videoRate) in [(1, 30), (2, 30), (3, 20)] {
      let request = try ScreenSharingCaptureIntervalRequest(
        videoFramesPerSecond: videoRate, overrideFramesPerSecond: profile.captureIntervalFPS(adaptiveLevel: level))
      #expect(request.requestedFramesPerSecond == videoRate && !request.isOverride)
    }
    #expect(try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 30, overrideFramesPerSecond: 120).isOverride)
    // The genuinely invalid direction is a request BELOW the video rate, which the single validated path rejects.
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingCaptureIntervalRequest(videoFramesPerSecond: 60, overrideFramesPerSecond: 30)
    }
  }

  // MARK: installation state machine

  /// Records every applied dictionary in order; the optional gate lets a test hold the apply open.
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var applied: [[String: String]] = []
    var onApply: (@Sendable ([String: String]) -> Void)?
    var count: Int { lock.lock(); defer { lock.unlock() }; return applied.count }
    var last: [String: String]? { lock.lock(); defer { lock.unlock() }; return applied.last }
    func record(_ trials: [String: String]) {
      lock.lock(); applied.append(trials); lock.unlock()
      onApply?(trials)
    }
  }

  @Test func theFirstSelectionIsAppliedOnceAndFixesTheProcess() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    #expect(trials.installed == nil)
    let installed = try trials.install(profile: .paced15Worker)
    #expect(installed.name == "paced15-worker")
    #expect(recorder.count == 1 && recorder.last == ["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:15"])
    #expect(trials.installed == installed)
    // Re-installing the same request changes nothing and applies nothing further.
    #expect(try trials.install(profile: .paced15Worker) == installed)
    #expect(recorder.count == 1)
    // ensureInstalled accepts what is in force rather than pinning the default over it.
    #expect(trials.ensureInstalled() == installed)
    #expect(recorder.count == 1)
  }

  @Test func provenanceNamesNeverCreateAFalseConflict() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    let first = try trials.install(
      .init(name: "probe options", trials: ["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:15"]))
    // Same native dictionary asked for under the product profile's name: idempotent, and the FIRST provenance wins.
    let second = try trials.install(profile: .paced15Worker)
    #expect(second == first && second.name == "probe options")
    #expect(recorder.count == 1)
  }

  @Test func aDifferentTrialMapFailsBeforeAnyPeerExists() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    try trials.install(profile: .paced15Worker)
    #expect(throws: ScreenSharingError.self) {
      try trials.install(.init(name: "probe options", trials: ["WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0"]))
    }
    #expect(throws: ScreenSharingError.self) { try trials.install(.default) }
    #expect(recorder.count == 1 && trials.installed?.name == "paced15-worker")
  }

  @Test func installingTheDefaultAlsoFixesTheProcessAgainstALaterProfile() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    let installed = trials.ensureInstalled()
    #expect(installed == .default && installed.playoutExperimentLabel == nil)
    #expect(recorder.count == 1 && recorder.last == [:])  // the empty apply is still a decision
    #expect(throws: ScreenSharingError.self) { try trials.install(profile: .paced15Worker) }
    #expect(trials.installed == .default && recorder.count == 1)
  }

  // MARK: ordering — readiness is not published until the apply returns

  @Test func readinessIsNotVisibleWhileTheApplyIsStillRunning() throws {
    let recorder = Recorder()
    let observed = Box(ScreenSharingFieldTrials.Selection.default)  // non-nil so a missed write fails the test
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    recorder.onApply = { [weak trials] _ in
      // Inside the apply, on the applying thread: the selection must NOT be observable yet.
      observed.value = trials?.installed
    }
    try trials.install(profile: .paced15Worker)
    #expect(observed.value == nil)
    #expect(trials.installed?.name == "paced15-worker")
  }

  @Test func aSecondCallerBlocksAtTheWaitingBoundaryUntilTheApplyReturns() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    let events = EventLog()
    let applyStarted = DispatchSemaphore(value: 0)
    let releaseApply = DispatchSemaphore(value: 0)
    // Signalled by whichever happens first: the second caller REACHING the wait, or the second caller returning.
    let secondProgressed = DispatchSemaphore(value: 0)
    let secondReturned = DispatchSemaphore(value: 0)
    let firstReturned = DispatchSemaphore(value: 0)

    // The internal observer fires exactly where a caller is about to block on the apply in progress.
    trials.onWaitingForApply = {
      events.append("secondReachedWait")
      secondProgressed.signal()
    }
    recorder.onApply = { _ in
      events.append("applyStarted")
      applyStarted.signal()
      releaseApply.wait()  // the test controls exactly when the apply finishes
      events.append("applyFinished")
    }
    DispatchQueue.global().async {
      _ = try? trials.install(profile: .paced15Worker)
      events.append("firstReturned")
      firstReturned.signal()
    }
    applyStarted.wait()  // the apply is in flight and has NOT returned
    DispatchQueue.global().async {
      let selection = trials.ensureInstalled()
      events.append("secondReturned(\(selection.name))")
      secondProgressed.signal()  // in case it returned without ever waiting (the regression this test targets)
      secondReturned.signal()
    }
    secondProgressed.wait()  // proceed only once the second caller has actually reached the wait, or returned early
    // Readiness must not have been published: a caller that returned here would have used an unapplied selection.
    #expect(events.entries.contains("secondReachedWait"))
    #expect(!events.entries.contains { $0.hasPrefix("secondReturned") })
    releaseApply.signal()
    firstReturned.wait()
    secondReturned.wait()
    let recorded = events.entries
    let applyFinished = try #require(recorded.firstIndex(of: "applyFinished"))
    let second = try #require(recorded.firstIndex(of: "secondReturned(paced15-worker)"))
    let reachedWait = try #require(recorded.firstIndex(of: "secondReachedWait"))
    #expect(reachedWait < applyFinished && applyFinished < second)
    #expect(recorded.first == "applyStarted")
    #expect(recorder.count == 1)  // single flight: the second caller never applied anything
  }

  /// Supporting evidence only: a broad concurrent smoke over the same boundary. The ordering guarantee itself is
  /// pinned by `aSecondCallerBlocksAtTheWaitingBoundaryUntilTheApplyReturns`.
  @Test func concurrentCallersApplyExactlyOnceAndAgreeOnTheResult() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    let results = EventLog()
    let group = DispatchGroup()
    for index in 0..<8 {
      DispatchQueue.global().async(group: group) {
        // Identical native map, eight different provenance names, plus ensureInstalled callers.
        if index % 2 == 0 {
          let selection = try? trials.install(
            .init(name: "caller \(index)", trials: ["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:15"]))
          results.append(selection?.trials["WebRTC-ForcePlayoutDelay"] ?? "threw")
        } else {
          results.append(trials.ensureInstalled().trials["WebRTC-ForcePlayoutDelay"] ?? "default")
        }
      }
    }
    group.wait()
    #expect(recorder.count == 1)  // single flight, whichever caller won
    let entries = results.entries
    #expect(entries.count == 8)
    let installed = try #require(trials.installed)
    let inForce = installed.trials["WebRTC-ForcePlayoutDelay"] ?? "default"
    // Nobody observed a half-installed state: every caller either agrees with what is in force, or -- only when an
    // `ensureInstalled` caller won and fixed the default first -- was refused for asking a different map.
    #expect(entries.allSatisfy { $0 == inForce || $0 == "threw" })
    if entries.contains("threw") { #expect(inForce == "default") }
    if inForce != "default" { #expect(entries.allSatisfy { $0 == inForce }) }
  }

  // MARK: real wiring boundaries

  @Test func theProbeOptionsSelectionCoversEveryExistingTrialCombination() throws {
    typealias Selection = ScreenSharingFieldTrials.Selection
    // The exact factory `ProbeOptions.fieldTrialSelection` forwards to.
    let none = Selection.probeOptions(jitterWindowFrames: nil, lowLatencyPlayout: false, playoutDelayBoundsMs: nil)
    #expect(none.trials.isEmpty && none.name == "default")
    #expect(
      Selection.probeOptions(jitterWindowFrames: nil, lowLatencyPlayout: true, playoutDelayBoundsMs: nil).trials
        == ["WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0"])
    for bounds in [(min: 1, max: 15), (min: 1, max: 35), (min: 0, max: 500)] {
      #expect(
        Selection.probeOptions(jitterWindowFrames: nil, lowLatencyPlayout: false, playoutDelayBoundsMs: bounds).trials
          == ["WebRTC-ForcePlayoutDelay": "min_ms:\(bounds.min),max_ms:\(bounds.max)"])
    }
    let jitter = Selection.probeOptions(
      jitterWindowFrames: 90, lowLatencyPlayout: false, playoutDelayBoundsMs: nil)
    #expect(jitter.trials == ["WebRTC-JitterEstimatorConfig": "max_frame_size_percentile:0.95,frame_size_window:90"])
    let both = Selection.probeOptions(jitterWindowFrames: 90, lowLatencyPlayout: true, playoutDelayBoundsMs: nil)
    #expect(both.trials.count == 2 && both.trials["WebRTC-ForcePlayoutDelay"] == "min_ms:0,max_ms:0")
    #expect(both.name == "probe options")
    // The probe's paced15 selection is exactly the product profile's native map, so the two roles never conflict.
    #expect(
      Selection.probeOptions(jitterWindowFrames: nil, lowLatencyPlayout: false, playoutDelayBoundsMs: (min: 1, max: 15))
        .installs(ScreenSharingDiagnosticProfile.paced15Worker.trialSelection))
  }

  /// Covers what the bootstrap itself does: it pins a selection and publishes labels derived only from the INSTALLED
  /// map. It does not exercise a factory: `ScreenSharingPeer.init` has no injection point (it is bound to `.process`)
  /// precisely so that no fake initializer can authorize a real RTC factory, and the ordering of bootstrap-before-
  /// factory inside `init` is therefore SOURCE-REVIEWED, not exercised here.
  @Test @MainActor func theBootstrapPinsASelectionAndLabelsOnlyWhatIsInstalled() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    try trials.install(profile: .paced15Worker)
    let metrics = ScreenSharingMetrics()
    let installed = ScreenSharingPeer.bootstrapTrials(trials, publishingInto: metrics)
    #expect(installed.trials == ["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:15"])
    // After the bootstrap returns, the applied selection is readable — what `init` relies on before building anything.
    #expect(trials.installed == installed)
    #expect(metrics.snapshot().labels["playoutExperiment"] == "WebRTC-ForcePlayoutDelay min_ms:1,max_ms:15")
    #expect(metrics.snapshot().labels["fieldTrialProvenance"] == "paced15-worker")
    #expect(recorder.count == 1)  // the bootstrap pinned the existing selection, it did not re-apply

    // With nothing installed, the bootstrap pins the default and publishes NO playout label (absence preserved).
    let plainRecorder = Recorder()
    let plainTrials = ScreenSharingFieldTrials(apply: { plainRecorder.record($0) })
    let plainMetrics = ScreenSharingMetrics()
    #expect(ScreenSharingPeer.bootstrapTrials(plainTrials, publishingInto: plainMetrics) == .default)
    #expect(plainMetrics.snapshot().labels["playoutExperiment"] == nil)
    #expect(plainMetrics.snapshot().labels["fieldTrialProvenance"] == "default")
    // and a profile request after that bootstrap fails instead of claiming to be active.
    #expect(throws: ScreenSharingError.self) { try plainTrials.install(profile: .paced15Worker) }
  }

  @Test @MainActor func provenanceAndActiveProfileAreSeparateFacts() throws {
    let recorder = Recorder()
    let trials = ScreenSharingFieldTrials(apply: { recorder.record($0) })
    // The probe (or another role) installed the identical map first, so provenance is NOT the profile name.
    try trials.install(.init(name: "probe options", trials: ["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:15"]))
    let metrics = ScreenSharingMetrics()
    ScreenSharingPeer.bootstrapTrials(trials, publishingInto: metrics)
    let labels = metrics.snapshot().labels
    #expect(labels["fieldTrialProvenance"] == "probe options")  // first installer's provenance, preserved
    #expect(labels["playoutExperiment"] == "WebRTC-ForcePlayoutDelay min_ms:1,max_ms:15")  // actual installed map
    // The product roles publish "active" from the validated profile whose settings they wire, which install(profile:)
    // has just proved compatible with the installed map — a different map would have thrown instead.
    #expect(
      try trials.install(profile: .paced15Worker).installs(ScreenSharingDiagnosticProfile.paced15Worker.trialSelection))
  }

  // NOT covered by a test, deliberately: that `ScreenSharingDiagnosticProfile.process()` parses once per process and
  // replays a cached configuration failure. It is a `static let` holding a `Result`, so exercising the caching would
  // mean either reading the live process environment (which an external configuration could change, and which proves
  // nothing about caching) or adding production machinery purely to observe Swift's static initialization. The pure
  // parser above is fully covered; the caching is reported as SOURCE-REVIEWED.

  // MARK: capture request state — the PURE value type only
  //
  // Scope, stated exactly: this covers `ScreenSharingCaptureRequestState` in isolation — that `validated` refuses an
  // out-of-range request without touching state, and that `commit` is what moves the stored request and its labels
  // together. It does NOT exercise the update transaction, a thrown apply, or a stale generation: those live in
  // `ScreenSharingCapture.applyIntervalUpdate`, which this file never calls. Root's separate
  // `ScreenSharingCaptureUpdateTransactionTests.swift` invokes that real transaction.

  @Test func theRequestStateRefusesAnInvalidRequestAndMovesStateAndLabelsOnlyOnCommit() throws {
    let metrics = ScreenSharingMetrics()
    var state = ScreenSharingCaptureRequestState(overrideFramesPerSecond: 120)
    let level0 = try ScreenSharingVideoConfiguration(width: 1920, height: 1080, framesPerSecond: 60)
    // Successful update at level 0: validate, (stream update succeeds), commit.
    let first = try state.validated(video: level0, override: 120)
    state.commit(override: 120, request: first, metrics: metrics)
    #expect(state.overrideFramesPerSecond == 120)
    #expect(metrics.snapshot().labels["captureRequestedMinimumFrameIntervalFPS"] == "120")
    #expect(metrics.snapshot().labels["captureRequestedFrameIntervalOverride"] == "120")

    // Validation failure (override below the new video rate): nothing is committed, nothing is relabelled.
    let level1 = try ScreenSharingVideoConfiguration(width: 1280, height: 720, framesPerSecond: 30)
    #expect(throws: ScreenSharingError.self) { try state.validated(video: level1, override: 20) }
    #expect(state.overrideFramesPerSecond == 120)
    #expect(metrics.snapshot().labels["captureRequestedMinimumFrameIntervalFPS"] == "120")

    // Validating alone changes nothing: the stored request and labels still describe the last COMMITTED request.
    // (Whether the transaction reaches commit after a thrown or stale apply is not decided here — see the note above.)
    let pending = try state.validated(video: level1, override: nil)
    #expect(pending.requestedFramesPerSecond == 30 && !pending.isOverride)
    #expect(state.overrideFramesPerSecond == 120)
    #expect(metrics.snapshot().labels["captureRequestedMinimumFrameIntervalFPS"] == "120")

    // Only a commit moves the stored request and its telemetry together.
    state.commit(override: nil, request: pending, metrics: metrics)
    #expect(state.overrideFramesPerSecond == nil)
    #expect(metrics.snapshot().labels["captureRequestedMinimumFrameIntervalFPS"] == "30")
    #expect(metrics.snapshot().labels["captureRequestedFrameIntervalOverride"] == "none")
  }
}

/// Single mutable cell shared across threads.
private final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?
  init(_ value: Value?) { stored = value }
  var value: Value? {
    get { lock.lock(); defer { lock.unlock() }; return stored }
    set { lock.lock(); stored = newValue; lock.unlock() }
  }
}

/// Append-only ordered log shared across threads.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
  var entries: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// The renderer selection the product viewer forwards for this profile, exercised on the real initializer.
@Suite @MainActor struct ScreenSharingDiagnosticProfileRendererTests {
  @Test func theProfileSelectsTheWorkerPathAndTheDefaultKeepsTheProductRenderer() throws {
    let profile = ScreenSharingDiagnosticProfile.paced15Worker
    let profiled = ScreenSharingMetrics()
    let worker = try ScreenSharingMetalView(
      mailbox: ScreenSharingFrameMailbox(), metrics: profiled, renderOnArrival: profile.renderOnArrival,
      maximumDrawableCount: profile.maximumDrawableCount, offMainPreparation: profile.offMainPreparation)
    var labels = profiled.snapshot().labels
    #expect(labels["renderPreparation"] == "off-main serial worker (diagnostic)")
    #expect(labels["drawableAcquisitionPath"] == "CAMetalLayer.nextDrawable on render worker, default timeout")
    #expect(labels["maximumDrawableCount"] == "2")
    #expect(labels["displaySync"] == "enabled")  // no unsynced option belongs to this profile
    #expect(labels["frameSelection"] == "before drawable acquisition")
    worker.stop()
    #expect(profiled.snapshot().labels["rendererStopped"] == "true")  // terminal stop preserved
    worker.stop()  // idempotent

    // Default (profile OFF): the product renderer is untouched — display-link drive, three drawables, main actor.
    let plain = ScreenSharingMetrics()
    let standard = try ScreenSharingMetalView(mailbox: ScreenSharingFrameMailbox(), metrics: plain)
    labels = plain.snapshot().labels
    #expect(labels["renderPreparation"] == "main actor (MTKView)")
    #expect(labels["drawableAcquisitionPath"] == "MTKView.currentDrawable on main actor")
    #expect(labels["maximumDrawableCount"] == "3")
    standard.stop()
  }

  // NOT covered here: the initializer's refusals (off-main without arrival rendering, a drawable count outside 2...3).
  // Attempting them in this test bundle aborted the process with an uncaught NSException whose stack ended in
  // `-[MTKView dealloc]`. That abort was observed interactively while writing Stage 3t and was NOT captured to any
  // file, so no crash log exists to cite and it has not been reproduced. The cause is UNRESOLVED — the stack showed
  // where the abort surfaced, which is not by itself evidence of an Apple allocation-contract defect. It is a
  // pre-existing failure-path limitation of testing this initializer, unchanged by Stage 3t, reported rather than
  // papered over; no renderer change is made for it here.
}
