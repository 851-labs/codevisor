public struct ServerUpdateActivity: Equatable, Sendable {
  public var stages: ServerUpdateStages
  public var statusMessage: String?
  public var progress: Double?
  public var migration: ServerMigrationProgress?

  public init(
    stages: ServerUpdateStages,
    statusMessage: String? = nil,
    progress: Double? = nil,
    migration: ServerMigrationProgress? = nil
  ) {
    self.stages = stages
    self.statusMessage = statusMessage
    self.progress = progress
    self.migration = migration
  }
}
