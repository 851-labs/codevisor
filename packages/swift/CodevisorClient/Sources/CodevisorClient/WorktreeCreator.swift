//  Eager worktree creation for the new-workspace flows. Under the
//  "1 workspace == 1 working directory" model, a worktree is created BEFORE
//  its workspace exists — there is no session yet, so this helper owns the
//  whole request/progress lifecycle that used to live on SessionController's
//  first-send path.

import CodevisorProtocol
import Foundation
import Observation

/// Creates a git worktree on the server and mirrors its live setup progress
/// (git output, checkout hooks, failures) into an observable
/// `SessionSetupPhase` that the new-workspace UIs render with the existing
/// setup-phase views.
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

  /// The live "Setting up worktree" phase. Nil until a creation starts;
  /// after a failure it holds the failed phase (message + logs) so the UI
  /// can keep it expanded next to a Try Again button.
  public private(set) var phase: SessionSetupPhase?
  /// Latches re-entry: a second activation while a request is in flight is
  /// ignored by callers guarding on this.
  public private(set) var isRunning = false

  public init() {}

  /// Clears the previous phase (e.g. when the user backs out of a failed
  /// creation and returns to the picker).
  public func reset() {
    guard !isRunning else { return }
    phase = nil
  }

  /// Asks the server to create a git worktree for the project. The server
  /// owns the fixed location (~/codevisor/{projectId}/{name}) and picks a
  /// random memorable name; the app never computes either. The worktree id
  /// is generated client-side so the server's `worktree.setup` events can
  /// be followed live into `phase` while the request is in flight — no
  /// session id is needed.
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
    // Best-effort live tail: the WebSocket usually opens well before git
    // (and any long checkout hooks) produce output. Terminal state comes
    // from the HTTP response, not from these events.
    let follow = Task { [weak self] in
      do {
        for try await envelope in client.eventStream(
          since: ServerSessionTransport.liveOnlyEventCursor
        ) {
          guard
            case let .log(stream, line) = WorktreeSetupEvent.from(
              envelope, worktreeId: worktreeId
            )
          else { continue }
          self?.phase?.appendLog(stream: stream, line: line)
        }
      } catch {
        // The stream is cosmetic; a drop just stops the live tail.
        Log.session.debug("worktree setup log tail dropped: \(String(describing: error), privacy: .public)")
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

  /// The server reports worktree failures as `{"error": "…"}` bodies.
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
