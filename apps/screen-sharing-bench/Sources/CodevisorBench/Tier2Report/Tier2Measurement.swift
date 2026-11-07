import ScreenSharingBench

struct Tier2Measurement {
  static let continuousScenes: Set<String> = ["typing", "scroll", "window-drag", "video"]
  static let unreadableLimit = 0.01
  static let unreadableExempt = "video"

  let files: Tier2RunFiles
  let clock: BenchClockTrack?
  let analysis: BenchSharingAnalysis?
  let bottom: Tier2BottomTile?
  let hostUsage: BenchUsageSummary?
  let viewerUsage: BenchUsageSummary?
  let inputToPhoton: BenchInputToPhoton?
  let invalidReason: String?
  let textFidelity: BenchTextFidelityAnalysis?
  let displayPhaseMs: Double?

  init(_ files: Tier2RunFiles) {
    let clock = BenchClockTrack(bursts: files.clockBursts.filter { !$0.isEmpty })
    let analysis = clock.flatMap { track in
      BenchSharingAnalysis(
        host: files.host, viewer: files.viewer, viewerNs: track.localNs(fromRemote:),
        countsFreezes: Self.continuousScenes.contains(files.meta.scene))
    }
    self.files = files
    self.clock = clock
    self.analysis = analysis
    bottom = clock.flatMap { clock in analysis.flatMap { Tier2BottomTile(files, clock: clock, window: $0.window) } }
    hostUsage = analysis.flatMap { Self.hostUsage(files, clock: clock, window: $0.window) }
    viewerUsage = analysis.map {
      BenchUsageSummary(files.viewerUsage, in: $0.window, processes: Tier2Processes.viewer(files.meta.system))
    }
    let inputToPhoton = Tier2InputRun.toPhoton(files)
    self.inputToPhoton = inputToPhoton
    invalidReason =
      Self.invalidReason(files, clock: clock, analysis: analysis)
      ?? Tier2InputRun.invalidReason(files, inputToPhoton)
    textFidelity = Self.textFidelity(files)
    displayPhaseMs = Tier2DisplayPhase.ms(host: files.host, viewer: files.viewer, clock: clock)
  }

  var result: BenchResult? {
    guard let system = files.meta.benchSystem, let analysis else { return nil }

    return Tier2Result.make(self, system: system, analysis: analysis)
  }

  private static func textFidelity(_ files: Tier2RunFiles) -> BenchTextFidelityAnalysis? {
    do {
      return try Tier2TextFidelity.analysis(of: files)
    } catch {
      BenchConsole.error("no text fidelity for \(files.directory.lastPathComponent): \(error)")
      return nil
    }
  }

  private static func hostUsage(
    _ files: Tier2RunFiles, clock: BenchClockTrack?, window: BenchSharingWindow
  ) -> BenchUsageSummary? {
    guard let clock, !files.hostUsage.isEmpty else { return nil }

    let mapped = files.hostUsage.map { second in
      var second = second
      second.endNs = clock.localNs(fromRemote: second.endNs)
      return second
    }
    return BenchUsageSummary(mapped, in: window, processes: Tier2Processes.host(files.meta.system))
  }

  static var hpVirtualDisplay: Regex<(Substring, Substring, Substring)> { /^1920x1080@(60|0) 2x(\s|$)/ }

  var streamSize: String? {
    files.meta.isCodevisor ? files.share?["capture_size"]?.string : nil
  }

  var encodedPixels: String? {
    switch files.meta.system {
    case .codevisor, .codevisorV2, .codevisorV2VCP: files.share?["capture_size"]?.string
    case .appleHP: files.hostDisplayDuringRun.map { "\($0) shown; HP's encoded size isn't visible" }
    case .floor: nil
    }
  }

  private static func hpDisplayMatches(_ files: Tier2RunFiles) -> Bool {
    files.hostDisplayDuringRun.map(isHPVirtualDisplay) ?? false
  }

  static func isHPVirtualDisplay(_ description: String) -> Bool {
    description.firstMatch(of: hpVirtualDisplay) != nil
  }

  private static func invalidReason(
    _ files: Tier2RunFiles, clock: BenchClockTrack?, analysis: BenchSharingAnalysis?
  ) -> String? {
    if let reason = runReason(files, clock: clock) { return reason }
    guard !files.meta.isLocalInputFloor else { return localFloorReason(files) }
    guard let analysis else { return "the observers never overlapped for longer than the warm-up" }
    guard files.meta.system != .appleHP || files.ranHighPerformance else {
      return "the bench did not choose High Performance"
    }
    guard files.meta.system != .appleHP || hpDisplayMatches(files) else { return "HP's display wasn't 1920x1080 @2x" }
    guard files.meta.system != .appleHP || files.hpSessionOnScreen else {
      return "Screen Sharing's window was off screen"
    }
    guard files.meta.networkLabel == Tier2Result.defaultNetwork || files.shapedPathProven else {
      return "\(files.meta.networkLabel) shaping not shown on this run's path"
    }
    guard files.meta.system != .appleHP || files.hpFocusLosses == 0 else {
      return "Screen Sharing lost focus during the run"
    }
    guard analysis.viewerUnreadableFraction <= unreadableLimit || files.meta.scene == unreadableExempt else {
      return "viewer unreadable fraction above 1%"
    }

    return nil
  }

  private static func runReason(_ files: Tier2RunFiles, clock: BenchClockTrack?) -> String? {
    guard files.meta.githubRunId?.isEmpty == false else { return "not a workflow run (development only)" }
    guard let clock else { return "no clock probes were answered" }
    guard clock.quality.epsilonMs <= ClockProbeResult.maximumEpsilonMs else { return "clock ε above 0.5 ms" }
    guard clock.quality.residualMs <= ClockProbeResult.maximumResidualMs else { return "clock residual above 0.2 ms" }
    guard !files.ciBusy else { return "a CI job ran on a mini during the run" }
    if let problem = files.preflightProblems.first { return "preflight: \(problem)" }

    return nil
  }

  private static func localFloorReason(_ files: Tier2RunFiles) -> String? {
    let window = Tier2InputRun.window(files)
    let frames = files.viewer.filter { window?.contains($0.ptsNs) ?? true }
    guard BenchObservedVersions(frames).unreadableFraction <= unreadableLimit else {
      return "viewer unreadable fraction above 1%"
    }

    return nil
  }
}
