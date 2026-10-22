public struct FirstLaunchSetupTiming: Equatable, Sendable {
  public var skipWithin: Duration
  public var maximumVisible: Duration
  public var settle: Duration
  public var harnessesTimeout: Duration
  public var projectsTimeout: Duration
  public var modelsTimeout: Duration
  public var revealPace: Duration = .milliseconds(140)
  public var harnessesCatchUp: Duration = .milliseconds(800)
  public var projectsCatchUp: Duration = .milliseconds(800)

  public static let standard = FirstLaunchSetupTiming(
    skipWithin: .milliseconds(500),
    maximumVisible: .seconds(15),
    settle: .milliseconds(400),
    harnessesTimeout: .seconds(5),
    projectsTimeout: .seconds(10),
    modelsTimeout: .seconds(6)
  )

  public init(
    skipWithin: Duration,
    maximumVisible: Duration,
    settle: Duration,
    harnessesTimeout: Duration,
    projectsTimeout: Duration,
    modelsTimeout: Duration
  ) {
    self.skipWithin = skipWithin
    self.maximumVisible = maximumVisible
    self.settle = settle
    self.harnessesTimeout = harnessesTimeout
    self.projectsTimeout = projectsTimeout
    self.modelsTimeout = modelsTimeout
  }
}
