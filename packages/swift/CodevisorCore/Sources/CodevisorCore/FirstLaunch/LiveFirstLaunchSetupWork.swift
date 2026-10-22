import CodevisorClient
import Observation

@MainActor
public final class LiveFirstLaunchSetupWork: FirstLaunchSetupWork {
  private let environment: AppEnvironment
  private let machineId = CodevisorMachine.local.id
  private lazy var feed = FirstRunStatusFeed(client: environment.machines.client(for: machineId))

  public init(environment: AppEnvironment) {
    self.environment = environment
  }

  public func startServer() async -> FirstLaunchServerStart {
    while true {
      switch environment.machines.availability(for: machineId) {
      case .ready: return .ready
      case .failed: return .failed
      case .waiting: await availabilityChange()
      }
    }
  }

  public func findHarnesses() async throws -> [String] {
    let status = try await feed.status { $0.harnesses != nil || $0.isFinal }
    if let harnesses = status.harnesses { return harnesses.map(\.name) }
    guard status.state == .notApplicable else { throw FirstLaunchStepFailure() }
    return try await installedHarnessNames()
  }

  public func addRecentProjects() async throws -> Int {
    let status = try await feed.status(where: \.isFinal)
    switch status.state {
    case .done: return status.addedProjects ?? 0
    case .notApplicable: return 0
    case .running, .failed: throw FirstLaunchStepFailure()
    }
  }

  public func loadModels() async throws {
    try await environment.configCache.warmCapabilities(
      forServer: machineId,
      client: environment.machines.client(for: machineId)
    )
  }

  private func installedHarnessNames() async throws -> [String] {
    try await environment.harnessService(for: machineId).allHarnesses()
      .filter { $0.readiness.resolvedState == .ready }
      .map(\.name)
  }

  private func availabilityChange() async {
    await withCheckedContinuation { continuation in
      withObservationTracking {
        _ = environment.machines.availability(for: machineId)
      } onChange: {
        continuation.resume()
      }
    }
  }
}
