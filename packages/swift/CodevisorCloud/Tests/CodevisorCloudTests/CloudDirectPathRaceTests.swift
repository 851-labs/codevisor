import CodevisorTestSupport
import ConcurrencyExtras
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
struct CloudDirectPathRaceTests {
  @Test("A queued callback from the old pipe cannot remove its replacement")
  func staleDisconnect() async throws {
    try await withMainSerialExecutor {
      let script = ProbeScript()
      let machine = ScriptedDirectMachine()
      script.answer("m1", with: machine)
      let controller = makePathController(script: script)
      defer { controller.dropAll() }
      let presence = testMachine("m1", publicKey: machine.machine.publicKey)
      controller.reconcile(machines: [presence])
      await settle(controller)
      let oldDown = try #require(script.downCallback("m1"))
      controller.drop(deviceId: "m1")
      controller.reconcile(machines: [presence])
      await settle(controller)
      oldDown()
      // The serial executor runs the queued disconnect before this actor read.
      let observed = Task { controller.machineIds.contains("m1") }
      #expect(await observed.value)
      #expect(script.probes == ["m1", "m1"])
    }
  }
}
