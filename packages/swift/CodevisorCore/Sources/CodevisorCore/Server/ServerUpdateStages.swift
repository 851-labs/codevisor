public struct ServerUpdateStages: Equatable, Sendable {
  public private(set) var current: ServerUpdateStage
  public private(set) var reached: Set<ServerUpdateStage>

  public init(_ stage: ServerUpdateStage) {
    current = stage
    reached = [stage]
  }

  public func wasSkipped(_ stage: ServerUpdateStage) -> Bool {
    stage < current && !reached.contains(stage)
  }

  public mutating func advance(to stage: ServerUpdateStage) {
    guard stage > current else { return }

    current = stage
    reached.insert(stage)
  }
}
