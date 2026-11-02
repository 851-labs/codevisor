public struct AppUpdateActivity: Equatable, Sendable {
  public var stage: AppUpdateStage
  public var statusMessage: String?
  public var progress: Double?

  public init(stage: AppUpdateStage, statusMessage: String? = nil, progress: Double? = nil) {
    self.stage = stage
    self.statusMessage = statusMessage
    self.progress = progress
  }
}
