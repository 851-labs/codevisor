import CodevisorClient
import Foundation
import Observation

@MainActor
public final class LiveFirstLaunchSetupWork: FirstLaunchSetupWork {
  private let environment: AppEnvironment
  private let folders: FirstRunFolderAccess
  private let machineId = CodevisorMachine.local.id
  private lazy var feed = FirstRunStatusFeed(client: environment.machines.client(for: machineId))

  public init(environment: AppEnvironment, folders: FirstRunFolderAccess) {
    self.environment = environment
    self.folders = folders
  }

  public func startServer(waitingOnUser: @escaping @MainActor (Bool) -> Void) async -> FirstLaunchServerStart {
    while true {
      waitingOnUser(environment.machines.isWaitingForGit(on: machineId))
      switch environment.machines.availability(for: machineId) {
      case .ready: return .ready
      case .failed: return .failed
      case .waiting: await availabilityChange()
      }
    }
  }

  public func isNewInstall() async throws -> Bool {
    try await environment.machines.client(for: machineId).firstRunStatus().isNewInstall
  }

  public func findHarnesses() async throws -> [String] {
    let status = try await feed.status { $0.harnesses != nil || $0.isFinal }
    if let harnesses = status.harnesses { return harnesses.map(\.name) }
    guard status.state == .notApplicable else { throw FirstLaunchStepFailure() }
    return try await installedHarnessNames()
  }

  public func addRecentProjects(
    progress: @escaping @MainActor ([String]) -> Void,
    waitingOnUser: @escaping @MainActor (Bool) -> Void
  ) async throws -> [String] {
    let reporting = Task { await self.reportFolderQuestions(to: waitingOnUser) }
    defer { reporting.cancel() }

    var reported = 0
    while true {
      let status = try await feed.status { Self.isSettled($0) || Self.projectNames(in: $0).count > reported }
      let names = Self.projectNames(in: status)
      reported = names.count
      progress(names)
      guard Self.isSettled(status) else { continue }
      return try finalProjectNames(status)
    }
  }

  private static func isSettled(_ status: ServerFirstRunStatus) -> Bool {
    status.isFinal && status.foldersToAsk.isEmpty
  }

  private func reportFolderQuestions(to waitingOnUser: @MainActor (Bool) -> Void) async {
    defer { waitingOnUser(false) }
    while !Task.isCancelled {
      waitingOnUser(folders.isAsking)
      await folderQuestionsChange()
    }
  }

  private func folderQuestionsChange() async {
    await withCheckedContinuation { continuation in
      withObservationTracking {
        _ = folders.isAsking
      } onChange: {
        continuation.resume()
      }
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
        _ = environment.machines.isWaitingForGit(on: machineId)
      } onChange: {
        continuation.resume()
      }
    }
  }
}
