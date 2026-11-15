import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@Suite("CloudDirectPathController redials", .timeLimit(.minutes(1)))
@MainActor
struct CloudDirectPathRedialTests {
  @MainActor
  private struct Live {
    let script = ProbeScript()
    let clock = TestClock()
    let controller: CloudDirectPathController

    init() {
      script.answer("m1", with: ScriptedDirectMachine())
      script.answer("m2", with: ScriptedDirectMachine())
      controller = makePathController(script: script, clock: clock)
      controller.reconcile(machines: [testMachine("m1", publicKey: "key"), testMachine("m2", publicKey: "key")])
    }

    func probes() -> Int { script.probes.filter { $0 == "m1" }.count }

    func bothUp() async {
      await settle(controller)
      #expect(controller.machineIds == ["m1", "m2"])
    }

    func dropAfterLiving(_ lived: Duration) async {
      script.answer("m1", with: nil)
      clock.advance(by: lived)
      script.takeDown("m1")
      _ = await waitUntil { !controller.machineIds.contains("m1") }
    }

    func elapse(_ wait: Duration, thenProbes expected: Int) async {
      await clock.waitForSleep(wait)
      clock.advance(by: wait - .milliseconds(1))
      #expect(probes() == expected - 1, "no dial before \(wait)")
      clock.advance(by: .milliseconds(1))
      #expect(await waitUntil { probes() == expected })
      await settle(controller)
    }
  }

  @Test("A live tunnel that drops redials at once, then after 1, 2 and 4 s, then falls back to the backoff")
  func quickRedialsThenBackoff() async {
    let live = Live()
    await live.bothUp()

    await live.dropAfterLiving(.seconds(30))
    #expect(await waitUntil { live.probes() == 2 })
    await settle(live.controller)

    await live.elapse(.seconds(1), thenProbes: 3)
    await live.elapse(.seconds(2), thenProbes: 4)
    await live.elapse(.seconds(4), thenProbes: 5)
    await live.clock.waitForSleep(.seconds(60))
    #expect(live.probes() == 5)
  }

  @Test("Quick redials end when one connects")
  func quickRedialConnects() async {
    let live = Live()
    await live.bothUp()

    await live.dropAfterLiving(.seconds(30))
    #expect(await waitUntil { live.probes() == 2 })
    await settle(live.controller)
    live.script.answer("m1", with: ScriptedDirectMachine())
    await live.elapse(.seconds(1), thenProbes: 3)

    #expect(live.controller.machineIds == ["m1", "m2"])
  }

  @Test("A tunnel that drops within 10 s of coming up is not redialed at once; it backs off")
  func shortLivedTunnelBacksOff() async {
    let live = Live()
    await live.bothUp()

    await live.dropAfterLiving(.seconds(5))

    await live.clock.waitForSleep(.seconds(60))
    #expect(live.probes() == 1)
    await live.elapse(.seconds(60), thenProbes: 2)
  }

  @Test("While a retry is waiting, opens and roster updates don't dial; a user's Retry does, at once")
  func backoffHoldsUntilRetry() async throws {
    let live = Live()
    await live.bothUp()
    await live.dropAfterLiving(.seconds(5))
    await live.clock.waitForSleep(.seconds(60))

    let open = Task { try await live.controller.awaitTransport(for: "m1", publicKey: "key") }
    await live.clock.waitForSleep(.seconds(15))
    live.controller.reconcile(machines: [testMachine("m1", publicKey: "key"), testMachine("m2", publicKey: "key")])
    #expect(live.probes() == 1)

    live.script.answer("m1", with: ScriptedDirectMachine())
    live.controller.redialNow("m1")
    #expect(try await open.value is CloudDirectTransport)
    #expect(live.probes() == 2)
  }
}
