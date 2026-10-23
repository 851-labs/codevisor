public struct FirstLaunchSetupTiming: Equatable, Sendable {
  public var maximumVisible: Duration
  public var settle: Duration
  public var harnessesTimeout: Duration
  public var projectsTimeout: Duration
  public var modelsTimeout: Duration
  public var revealPace: Duration = .milliseconds(140)
  public var catchUp: Duration = .milliseconds(800)
  public var serverAnswerTimeout: Duration = .seconds(15)
  public var serverAnswerRetry: Duration = .milliseconds(500)

  public static let standard = FirstLaunchSetupTiming(
    maximumVisible: .seconds(15),
    settle: .milliseconds(400),
    harnessesTimeout: .seconds(5),
    projectsTimeout: .seconds(10),
    modelsTimeout: .seconds(12)
  )

  public init(
    maximumVisible: Duration,
    settle: Duration,
    harnessesTimeout: Duration,
    projectsTimeout: Duration,
    modelsTimeout: Duration
  ) {
    self.maximumVisible = maximumVisible
    self.settle = settle
    self.harnessesTimeout = harnessesTimeout
    self.projectsTimeout = projectsTimeout
    self.modelsTimeout = modelsTimeout
  }
}
