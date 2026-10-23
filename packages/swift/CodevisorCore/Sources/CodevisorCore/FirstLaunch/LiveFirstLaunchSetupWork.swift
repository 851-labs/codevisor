import CodevisorClient
import Foundation
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

  public func addRecentProjects(progress: @escaping @MainActor ([String]) -> Void) async throws -> [String] {
    var reported = 0
    while true {
      let status = try await feed.status { $0.isFinal || Self.projectNames(in: $0).count > reported }
      let names = Self.projectNames(in: status)
      reported = names.count
      progress(names)
      guard status.isFinal else { continue }
      return try finalProjectNames(status)
    }
  }

  private func finalProjectNames(_ status: ServerFirstRunStatus) throws -> [String] {
    switch status.state {
    case .done: return Self.projectNames(in: status)
    case .notApplicable: return []
    case .running, .failed: throw FirstLaunchStepFailure()
    }
  }

  private static func projectNames(in status: ServerFirstRunStatus) -> [String] {
    status.projects?.map(\.name) ?? []
  }

  public func loadModels() async throws {
    let preparation = Task { try await self.prepareModels() }
    try await preparation.value
  }

  private func prepareModels() async throws {
    _ = try await environment.settleHarnessAuthentication(onServer: machineId)
    _ = try await warmCapabilitiesSurvivingInvalidation()
  }

  private func warmCapabilitiesSurvivingInvalidation() async throws -> [ServerHarnessCapability] {
    var attempt = 1
    while true {
      do {
        return try await environment.configCache.warmCapabilities(
          forServer: machineId,
          client: environment.machines.client(for: machineId)
        )
      } catch  where Self.wasCancelledByInvalidation(error) && attempt < Self.warmAttempts && !Task.isCancelled {
        attempt += 1
      }
    }
  }

  private static func wasCancelledByInvalidation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }

  private static let warmAttempts = 8

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
