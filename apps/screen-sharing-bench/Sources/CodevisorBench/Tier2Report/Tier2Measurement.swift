import ScreenSharingBench

struct Tier2Measurement {
  static let continuousScenes: Set<String> = ["typing", "scroll", "window-drag", "video"]
  static let unreadableLimit = 0.01
  static let unreadableExempt = "video"

  let files: Tier2RunFiles
  let clock: BenchClockTrack?
  let analysis: BenchSharingAnalysis?
  let hostUsage: BenchUsageSummary?
  let viewerUsage: BenchUsageSummary?
  let invalidReason: String?

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
    hostUsage = analysis.flatMap { Self.hostUsage(files, clock: clock, window: $0.window) }
    viewerUsage = analysis.map {
      BenchUsageSummary(files.viewerUsage, in: $0.window, processes: Tier2Processes.viewer(files.meta.system))
    }
    invalidReason = Self.invalidReason(files, clock: clock, analysis: analysis)
  }

  var result: BenchResult? {
    guard let system = benchSystem, let analysis else { return nil }

    return Tier2Result.make(self, system: system, analysis: analysis)
  }

  private var benchSystem: BenchSystem? {
    switch files.meta.system {
    case .appleHP: .appleHP
    case .codevisor: .codevisor
    case .floor: nil
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

  var encodedPixels: String? {
    switch files.meta.system {
    case .codevisor: files.share?["capture_size"]?.string
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
    guard files.meta.githubRunId?.isEmpty == false else { return "not a workflow run (development only)" }
    guard let clock else { return "no clock probes were answered" }
    guard clock.quality.epsilonMs <= ClockProbeResult.maximumEpsilonMs else { return "clock ε above 0.5 ms" }
    guard clock.quality.residualMs <= ClockProbeResult.maximumResidualMs else { return "clock residual above 0.2 ms" }
    guard let analysis else { return "the observers never overlapped for longer than the warm-up" }
    guard !files.ciBusy else { return "a CI job ran on a mini during the run" }
    if let problem = files.preflightProblems.first { return "preflight: \(problem)" }
    guard files.meta.system != .appleHP || files.ranHighPerformance else {
      return "the bench did not choose High Performance"
    }
    guard files.meta.system != .appleHP || hpDisplayMatches(files) else { return "HP's display wasn't 1920x1080 @2x" }
    guard files.meta.system != .appleHP || files.hpSessionOnScreen else {
      return "Screen Sharing's window was off screen"
    }
    guard files.meta.system != .appleHP || files.hpFocusLosses == 0 else {
      return "Screen Sharing lost focus during the run"
    }
    guard analysis.viewerUnreadableFraction <= unreadableLimit || files.meta.scene == unreadableExempt else {
      return "viewer unreadable fraction above 1%"
    }

    return nil
  }
}
