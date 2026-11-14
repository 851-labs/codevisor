import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("The app's screen share connections", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionsTests {
  private typealias Fixture = ScreenSharingConnectionsFixture

  @Test("Every caller gets the machine's one connection, and another machine gets its own")
  func handsOutOneConnectionPerMachine() throws {
    let fixture = Fixture()
    fixture.machineIds.insert("tamale")

    let croissant = try fixture.connections.connection(for: Fixture.machineId)
    #expect(try fixture.connections.connection(for: Fixture.machineId) === croissant)
    #expect(try fixture.connections.connection(for: "tamale") !== croissant)
  }

  @Test("The app presents its name and the key its signer proves, with ids derived from that key")
  func presentsTheAppIdentity() async throws {
    let fixture = Fixture()
    try fixture.show()
    try await fixture.goLive()

    let start = try #require(fixture.host.starts.first)
    #expect(start.app == ServerScreenSharingApp(key: FakeMedia.address.endpointId, name: Fixture.appName))
    #expect(start.workspaceId == UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    #expect(start.paneId == start.workspaceId)
  }

  @Test("A key that can't be read fails the caller instead of starting an unsigned connection")
  func refusesWithoutAKey() {
    let fixture = Fixture()
    fixture.signerFails = true

    #expect(throws: FakeSigner.Failure.self) { _ = try fixture.connections.connection(for: Fixture.machineId) }
  }

  @Test("A machine that is removed, or signed out of, ends its connection, and coming back starts a new one")
  func endsTheConnectionOfARemovedMachine() async throws {
    let fixture = Fixture()
    let first = try fixture.connection
    try fixture.show()
    try await fixture.goLive()

    fixture.machineIds = []
    await awaitObserved { first.isEnded }
    await awaitObserved { fixture.host.stops.count == 1 }

    fixture.machineIds = [Fixture.machineId]
    #expect(try fixture.connection !== first)
  }

  @Test("Quitting ends every connection and stops the host's session")
  func endsEverythingOnQuit() async throws {
    let fixture = Fixture()
    let connection = try fixture.connection
    try fixture.show()
    try await fixture.goLive()

    fixture.connections.shutdown()

    #expect(connection.isEnded)
    await awaitObserved { fixture.host.stops.count == 1 }
  }

  @Test("A machine that becomes ready again reconnects a connection that couldn't reach it")
  func reconnectsWhenTheMachineIsReadyAgain() async throws {
    let fixture = Fixture()
    fixture.readyMachineIds = []
    fixture.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    try fixture.show()
    await fixture.settle(.failed(.cantReach))

    fixture.host.answerEvery(.capabilities, nil)
    fixture.readyMachineIds = [Fixture.machineId]
    try await fixture.goLive()

    #expect(fixture.host.starts.map(\.intent) == [.attach])
  }

  @Test("Waking this Mac reconnects a live connection as an attach")
  func reconnectsAfterThisMacWakes() async throws {
    let fixture = Fixture()
    try fixture.show()
    try await fixture.goLive()

    fixture.wake()
    await fixture.settle(.reconnecting)
    try await fixture.goLive()

    #expect(fixture.host.starts.map(\.intent) == [.attach, .attach])
  }

  @Test("An old host is given the workspace shown last, and never an archived or unsynced one")
  func picksALiveWorkspaceForAnOldHost() async throws {
    let fixture = Fixture(host: .old())
    let (archived, draft) = (Fixture.workspace(archived: true), Fixture.workspace(synced: false))
    let (first, shown, elsewhere) = (Fixture.workspace(), Fixture.workspace(), Fixture.workspace(on: "tamale"))
    fixture.workspaces = [archived, draft, elsewhere, first, shown]
    fixture.connections.surfaceShown(inWorkspace: archived.id, onMachine: Fixture.machineId)
    try fixture.show()
    try await fixture.goLive()
    #expect(fixture.host.starts.map(\.workspaceId) == [first.id])

    fixture.connections.surfaceShown(inWorkspace: shown.id, onMachine: Fixture.machineId)
    fixture.wake()
    await fixture.settle(.reconnecting)
    try await fixture.goLive()
    #expect(fixture.host.starts.map(\.workspaceId) == [first.id, shown.id])
  }

  @Test("A surface shown in a workspace revives a connection that failed for lack of one")
  func revivesWhenAWorkspaceIsShown() async throws {
    let fixture = Fixture(host: .old())
    try fixture.show()
    await fixture.settle(.failed(.noWorkspace))

    let workspace = Fixture.workspace()
    fixture.workspaces = [workspace]
    fixture.connections.surfaceShown(inWorkspace: workspace.id, onMachine: Fixture.machineId)
    try await fixture.goLive()

    #expect(fixture.host.starts.map(\.workspaceId) == [workspace.id])
  }
}
