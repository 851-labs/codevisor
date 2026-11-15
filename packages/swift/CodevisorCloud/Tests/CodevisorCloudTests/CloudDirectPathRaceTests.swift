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
      let observed = Task { controller.machineIds.contains("m1") }
      #expect(await observed.value)
      #expect(script.probes == ["m1", "m1"])
    }
  }

  @Test("A tunnel that dies between verifying and being stored is dialed again, not kept")
  func diesBeforeHandover() async throws {
    try await withMainSerialExecutor {
      let script = ProbeScript()
      let machine = ScriptedDirectMachine()
      script.answer("m1", with: machine)
      script.dieBeforeHandover("m1")
      let controller = makePathController(script: script)
      defer { controller.dropAll() }
      controller.reconcile(machines: [testMachine("m1", publicKey: machine.machine.publicKey)])

      await settle(controller)
      await settle(controller)

      #expect(script.probes == ["m1", "m1"])
      #expect(controller.machineIds == ["m1"])
      let stored = try #require(controller.transport(for: "m1", publicKey: machine.machine.publicKey))
      #expect(await (stored as? CloudDirectTransport)?.connection.hasGoneDown == false)
    }
  }

  @Test("An open that finds a stored tunnel already down dials a fresh one")
  func openReplacesADeadTunnel() async throws {
    let script = ProbeScript()
    let machine = ScriptedDirectMachine()
    script.answer("m1", with: machine)
    let controller = makePathController(script: script)
    defer { controller.dropAll() }
    let key = machine.machine.publicKey
    controller.reconcile(machines: [testMachine("m1", publicKey: key)])
    await settle(controller)
    let dead = try #require(controller.transport(for: "m1", publicKey: key) as? CloudDirectTransport)
    await dead.connection.shutdown()

    let opened = try await controller.awaitTransport(for: "m1", publicKey: key)

    #expect(script.probes == ["m1", "m1"])
    let fresh = try #require(opened as? CloudDirectTransport)
    #expect(fresh.connection !== dead.connection)
    #expect(await fresh.connection.hasGoneDown == false)
  }

  @Test("A tunnel that keeps dying before it's stored is redialed at once only once, then backs off")
  func repeatedEarlyDropsBackOff() async throws {
    try await withMainSerialExecutor {
      let script = ProbeScript()
      let clock = TestClock()
      let machine = ScriptedDirectMachine()
      script.answer("m1", with: machine)
      script.dieBeforeHandover("m1", times: 2)
      let controller = makePathController(script: script, clock: clock)
      defer { controller.dropAll() }
      controller.reconcile(machines: [testMachine("m1", publicKey: machine.machine.publicKey)])
      await settle(controller)
      await settle(controller)

      try #require(script.probes == ["m1", "m1"])
      #expect(controller.machineIds.isEmpty)
      await clock.waitForSleep(.seconds(60))
      clock.advance(by: .seconds(60) - .milliseconds(1))
      #expect(script.probes == ["m1", "m1"])

      clock.advance(by: .milliseconds(1))
      #expect(await waitUntil { controller.machineIds == ["m1"] })
      #expect(script.probes == ["m1", "m1", "m1"])
    }
  }
}
