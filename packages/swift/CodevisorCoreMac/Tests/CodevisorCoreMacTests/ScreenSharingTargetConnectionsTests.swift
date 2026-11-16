import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("Screen sharing connections: a simulator's own connection on a machine", .timeLimit(.minutes(1)))
struct ScreenSharingTargetConnectionsTests {
  typealias Fixture = ScreenSharingConnectionsFixture

  private static let simulator = "simulator:0B000000-0000-4000-8000-000000000001"

  private func target(_ fixture: Fixture, _ target: String = simulator) -> ScreenSharingConnection? {
    fixture.connections.targetConnection(onMachine: Fixture.machineId, target: target)
  }

  @Test("A target has its own connection next to the machine's desktop, and ending it leaves the desktop alone")
  func keepsATargetApartFromTheDesktop() throws {
    let fixture = Fixture()
    let desktop = try fixture.connection
    let simulator = try #require(target(fixture))

    #expect(simulator !== desktop && simulator.target == Self.simulator && target(fixture) === simulator)

    fixture.connections.endTargetConnection(onMachine: Fixture.machineId, target: Self.simulator)
    #expect(simulator.isEnded && !desktop.isEnded)
    let fresh = try #require(target(fixture))
    #expect(fresh !== simulator)
  }

  @Test("A target's requests carry the app's identity and name the target")
  func sendsTheTargetAsTheApp() async throws {
    let fixture = Fixture()
    let simulator = try #require(target(fixture))
    let surface = simulator.attach(.tab)
    surface.setOnScreen(true)
    await awaitObserved { fixture.media.sessions.first?.tokens.count == 1 }

    let start = try #require(fixture.host.starts.first)
    #expect(start.displayId == Self.simulator && start.app?.name == Fixture.appName)
    #expect(fixture.media.sessions.first?.presentsTiles == false)
    surface.detach()
  }

  @Test("Whether a target is active is asked as the app, and only a listed target counts")
  func asksWhetherATargetIsActiveAsTheApp() async {
    let fixture = Fixture()
    let isActive = { await fixture.connections.targetIsActive(onMachine: Fixture.machineId, target: Self.simulator) }
    #expect(await isActive() == false)

    fixture.host.displays.append(.init(id: Self.simulator, name: "iPhone 17", width: 1206, height: 2622))
    #expect(await isActive() == true)
    let asked = fixture.host.requests(.capabilities)
    #expect(asked.map(\.displayId) == [Self.simulator, Self.simulator])
    #expect(asked.allSatisfy { $0.app?.name == Fixture.appName && $0.app?.key == fixture.signer.signer.key })

    fixture.host.answerEvery(.capabilities, .reply(status: "unavailable"))
    #expect(await isActive() == false)
    fixture.host.answerEvery(.capabilities, .reply(status: "permission-required"))
    #expect(await isActive() == nil)
    fixture.machineIds = []
    #expect(await isActive() == nil)
  }

  @Test("A target on a machine that is unknown, or whose key can't be read, has no connection")
  func refusesWithoutAMachineOrAKey() {
    let fixture = Fixture()
    fixture.signerFails = true
    #expect(target(fixture) == nil)

    fixture.signerFails = false
    fixture.machineIds = []
    #expect(target(fixture) == nil)
  }

  @Test("Removing the machine ends its targets, with no desktop connection needed to notice")
  func endsTargetsWithTheirMachine() async throws {
    let fixture = Fixture()
    let simulator = try #require(target(fixture))

    fixture.machineIds = []

    await awaitObserved { simulator.isEnded }
  }

  @Test("A machine that becomes ready again reconnects a target that couldn't reach it")
  func reconnectsATargetWhenTheMachineIsReadyAgain() async throws {
    let fixture = Fixture()
    fixture.readyMachineIds = []
    fixture.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    let simulator = try #require(target(fixture))
    let surface = simulator.attach(.tab)
    surface.setOnScreen(true)
    await awaitObserved { simulator.state == .failed(.cantReach) }

    fixture.host.answerEvery(.capabilities, nil)
    fixture.readyMachineIds = [Fixture.machineId]

    await awaitObserved { fixture.media.sessions.first?.tokens.count == 1 }
    surface.detach()
  }
}
