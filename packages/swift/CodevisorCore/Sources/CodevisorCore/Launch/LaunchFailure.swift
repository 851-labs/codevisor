public struct LaunchFailure: Equatable, Sendable {
  public enum Stage: Equatable, Sendable {
    case localData
    case server
    case dataUpgrade
  }

  public let stage: Stage
  public let message: String

  public init(stage: Stage, message: String) {
    self.stage = stage
    self.message = message
  }

  public var canContinue: Bool { stage != .localData }

  public var title: String {
    switch stage {
    case .localData: "Codevisor Couldn't Open Its Data"
    case .server: "Codevisor Couldn't Start"
    case .dataUpgrade: "Codevisor Couldn't Update Your Data"
    }
  }
}
