public struct FirstLaunchSetupTiming: Equatable, Sendable {
  public var skipWithin: Duration
  public var minimumVisible: Duration
  public var maximumVisible: Duration
  public var settle: Duration
  public var harnessesTimeout: Duration
  public var projectsTimeout: Duration
  public var modelsTimeout: Duration

  public static let standard = FirstLaunchSetupTiming(
    skipWithin: .milliseconds(500),
    minimumVisible: .milliseconds(1_500),
    maximumVisible: .seconds(15),
    settle: .milliseconds(400),
    harnessesTimeout: .seconds(5),
    projectsTimeout: .seconds(10),
    modelsTimeout: .seconds(6)
  )

  public init(
    skipWithin: Duration,
    minimumVisible: Duration,
    maximumVisible: Duration,
    settle: Duration,
    harnessesTimeout: Duration,
    projectsTimeout: Duration,
    modelsTimeout: Duration
  ) {
    self.skipWithin = skipWithin
    self.minimumVisible = minimumVisible
    self.maximumVisible = maximumVisible
    self.settle = settle
    self.harnessesTimeout = harnessesTimeout
    self.projectsTimeout = projectsTimeout
    self.modelsTimeout = modelsTimeout
  }
}
