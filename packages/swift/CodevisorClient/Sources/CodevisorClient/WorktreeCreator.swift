import CodevisorProtocol
import Foundation
import Observation

@MainActor
@Observable
public final class WorktreeCreator {
  public enum Failure: Error, Equatable {
    case message(String)

    public var message: String {
      switch self {
      case let .message(text): text
      }
    }
  }

  public private(set) var phase: SessionSetupPhase?
  public private(set) var isRunning = false

  public init() {}

  public func reset() {
    guard !isRunning else { return }
    phase = nil
  }

  public func create(
    projectId: UUID,
    client: (any CodevisorServerClienting)?
  ) async -> Result<ServerWorktree, Failure> {
    guard !isRunning else {
      return .failure(.message("A worktree is already being created."))
    }
    guard let client else {
      return .failure(
        .message(
          "Worktrees need the Codevisor server. Start it and try again."
        ))
    }
    isRunning = true
    defer { isRunning = false }

    let worktreeId = UUID().uuidString.lowercased()
    phase = .worktree()
    let log = WorktreeSetupEvent.liveLog(client, worktreeId: worktreeId)
    let follow = Task { [weak self] in
      for await entry in log {
        self?.phase?.appendLog(stream: entry.stream, line: entry.line)
      }
    }
    defer { follow.cancel() }

    do {
      let worktree = try await client.createWorktree(
        projectId: projectId,
        id: worktreeId,
        name: nil
      )
      phase?.succeed()
      return .success(worktree)
    } catch let CodevisorServerClientError.httpStatus(_, message) {
      let failure = Self.failureMessage(from: message)
      phase?.fail(message: failure)
      return .failure(.message(failure))
    } catch {
      let failure = serverErrorMessage(error)
      phase?.fail(message: failure)
      return .failure(.message(failure))
    }
  }

  public static func failureMessage(from body: String) -> String {
    guard let data = body.data(using: .utf8),
      let payload = try? JSONDecoder().decode([String: String].self, from: data),
      let error = payload["error"]
    else {
      return body.isEmpty ? "Could not create the worktree." : body
    }
    return error
  }
}
