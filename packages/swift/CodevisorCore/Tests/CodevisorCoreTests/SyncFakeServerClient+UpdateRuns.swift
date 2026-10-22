import ACPKit
import Foundation

@testable import CodevisorCore

extension SyncFakeServerClient {
  func configureUpdateRunInProgress(polls: Int) {
    lock.withLock { _updateRunActivePolls = polls }
  }

  func startUpdateRun(_ request: ServerUpdateRunRequest) async throws -> ServerUpdateRunStarted {
    if lock.withLock({ updateRunUnsupported }) {
      throw CodevisorServerClientError.httpStatus(404, "{\"error\":\"Route not found\"}")
    }
    lock.withLock { _operationLog.append(Self.describe(request)) }
    for harnessId in request.harnessIds {
      _ = try? await updateHarness(id: harnessId)
    }
    var server: ServerUpdateApplied?
    if let channel = request.serverChannel.flatMap(ServerUpdateChannel.init(rawValue:)) {
      server = try await applyServerUpdate(channel: channel)
    }
    let settled = request.holdForAppUpdate == true ? "holding" : "idle"
    return lock.withLock {
      _updateRunSettled = ServerUpdateRunState(state: settled, harnessIds: request.harnessIds)
      return ServerUpdateRunStarted(
        run: ServerUpdateRunState(state: "pausing", harnessIds: request.harnessIds, pausing: 1),
        server: server
      )
    }
  }

  func updateRunState() async throws -> ServerUpdateRunState {
    lock.withLock {
      guard _updateRunActivePolls > 0 else { return _updateRunSettled }
      _updateRunActivePolls -= 1
      return ServerUpdateRunState(state: "updating", harnessIds: _updateRunSettled.harnessIds)
    }
  }

  func cancelUpdateRun() async throws -> ServerUpdateRunState {
    lock.withLock {
      _operationLog.append("update.run.cancel")
      _updateRunSettled = .idle
      return .idle
    }
  }

  func cancelRestartDrain() async throws {
    lock.withLock { _operationLog.append("restart.drain.cancel") }
  }

  private static func describe(_ request: ServerUpdateRunRequest) -> String {
    let server = request.serverChannel == nil ? "" : "+server"
    let hold = request.holdForAppUpdate == true ? "+hold" : ""
    return "update.run:\(request.harnessIds.joined(separator: ","))\(server)\(hold)"
  }
}
