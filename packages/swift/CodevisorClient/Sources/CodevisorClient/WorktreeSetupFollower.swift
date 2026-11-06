import Foundation

public struct WorktreeSetupFailure: LocalizedError, Equatable, Sendable {
  public let message: String

  public var errorDescription: String? { message }
}

public struct WorktreeSetupFollower: Sendable {
  public static let recheckInterval: Duration = .seconds(5)
  static let fallbackFailureMessage = "Could not create the worktree."

  private let client: any CodevisorServerClienting
  private let projectId: UUID
  private let worktreeId: String
  private let name: String?
  private let recheckInterval: Duration
  private let clock: any Clock<Duration>

  public init(
    client: any CodevisorServerClienting,
    projectId: UUID,
    worktreeId: String,
    name: String? = nil,
    recheckInterval: Duration = WorktreeSetupFollower.recheckInterval,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.client = client
    self.projectId = projectId
    self.worktreeId = worktreeId
    self.name = name
    self.recheckInterval = recheckInterval
    self.clock = clock
  }

  public func run() async throws -> ServerWorktree {
    let tail = WorktreeSetupSignal.events(client, worktreeId: worktreeId)
    var status = try await started()
    if let worktree = try finished(status) { return worktree }

    let signals = WorktreeSetupSignal.stream(
      from: tail, worktreeId: worktreeId, recheckEvery: recheckInterval, clock: clock)
    var pending = signals.makeAsyncIterator()
    while true {
      status = try await next(from: &pending)
      if let worktree = try finished(status) { return worktree }
    }
  }

  private func next(
    from pending: inout AsyncStream<WorktreeSetupSignal>.Iterator
  ) async throws -> ServerWorktreeSetupStatus {
    switch await pending.next() {
    case let .created(worktree): .completed(worktree)
    case let .failed(message): .failed(worktreeId, message: message)
    case .recheck: try await refreshed()
    case nil: throw CancellationError()
    }
  }

  private func started() async throws -> ServerWorktreeSetupStatus {
    do {
      return try await client.startWorktreeSetup(projectId: projectId, id: worktreeId, name: name)
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return .completed(try await client.createWorktree(projectId: projectId, id: worktreeId, name: name))
    } catch  where ServerConnectionLoss.isConnectionLoss(error) {
      return .running(worktreeId)
    }
  }

  private func refreshed() async throws -> ServerWorktreeSetupStatus {
    do {
      return try await client.worktreeSetupStatus(projectId: projectId, worktreeId: worktreeId)
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return try await started()
    } catch  where ServerConnectionLoss.isConnectionLoss(error) {
      return .running(worktreeId)
    }
  }

  private func finished(_ status: ServerWorktreeSetupStatus) throws -> ServerWorktree? {
    switch status.state {
    case .running:
      return nil
    case .completed:
      guard let worktree = status.worktree else { throw CodevisorServerClientError.invalidResponse }
      return worktree
    case .failed:
      throw WorktreeSetupFailure(message: status.message ?? Self.fallbackFailureMessage)
    }
  }
}
