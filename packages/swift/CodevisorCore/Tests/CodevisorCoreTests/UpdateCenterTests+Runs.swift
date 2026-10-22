import Foundation
import Testing
@testable import CodevisorCore

extension UpdateCenterTests {
  @Test(
    "A harness row follows its machine's update run",
    arguments: [
      (ServerUpdateRunState(state: "pausing", harnessIds: ["claude-code"], pausing: 3), "Pausing 3 chats…"),
      (ServerUpdateRunState(state: "pausing", harnessIds: ["claude-code"], pausing: 1), "Pausing 1 chat…"),
      (ServerUpdateRunState(state: "pausing", harnessIds: ["claude-code"]), "Pausing chats…"),
      (
        ServerUpdateRunState(state: "updating", harnessIds: ["codex", "claude-code"], currentHarnessId: "codex"),
        "Waiting to update…"
      ),
      (
        ServerUpdateRunState(state: "updating", harnessIds: ["claude-code"], currentHarnessId: "claude-code"),
        "Updating to 1.2.0…"
      ),
      (ServerUpdateRunState(state: "continuing", harnessIds: ["claude-code"]), "Continuing chats…"),
    ]
  )
  func harnessRowFollowsTheRun(run: ServerUpdateRunState, message: String) async throws {
    let local = SyncFakeServerClient(projects: [], sessions: [])
    var preparing = makeHarness(updateAvailable: true)
    preparing.lifecycle = ServerHarnessLifecycleState(phase: "updating", targetVersion: "1.2.0")
    local.configureHarnesses([preparing])
    let controller = try makeController(fakes: ["local": local], remotes: [])
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    await center.refresh()

    controller.connection(for: "local").updateRun = run

    let row = try #require(center.components.first { $0.kind == .harness })
    #expect(row.phase == .updating)
    #expect(row.statusMessage == message)
  }

  @Test("Only a pause for harness chats alone can be cancelled from the row")
  func cancelWhilePausing() async throws {
    let local = SyncFakeServerClient(projects: [], sessions: [])
    local.configureHarnesses([makeHarness(updateAvailable: true)])
    let controller = try makeController(fakes: ["local": local], remotes: [])
    defer { controller.stopEventSync() }
    let center = UpdateCenter(machines: controller, appUpdate: AppUpdateModel(currentVersion: "1.0.0"))
    await center.refresh()
    let connection = controller.connection(for: "local")
    connection.updateRun = ServerUpdateRunState(state: "pausing", harnessIds: ["claude-code"], pausing: 2)
    connection.restartDrain = ServerRestartDrainState(state: "draining", remaining: 2)
    let restartRow = try #require(center.components.first { $0.kind == .harness })
    #expect(!restartRow.canCancel)
    await center.cancel(restartRow)
    #expect(local.operationLog.isEmpty)

    connection.restartDrain = ServerRestartDrainState(state: "draining", remaining: 2, harnessIds: ["claude-code"])
    let row = try #require(center.components.first { $0.kind == .harness })
    #expect(row.canCancel)
    await center.cancel(row)

    #expect(local.operationLog == ["update.run.cancel"])
    #expect(connection.updateRun == .idle)
  }
}
