import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostDisplayIdentityTests {
  typealias Fixture = ScreenSharingHostOwnershipFixture

  private static let standInWhileVirtual = ServerScreenSharingDisplay(
    id: "stand-in", name: "Display", width: 3840, height: 2160)

  @Test func anAppNeverSeesTheHostsVirtualDisplay() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.hostVirtual, Fixture.main, Fixture.side]

      #expect(await mac.capabilities(as: .macBook).displays == [Fixture.main, Fixture.side])
    }
  }

  @Test func aHeadlessMacsDisplayKeepsItsIDThroughTheSwapToTheVirtualDisplayAndBack() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.standIn]
      let granted = await mac.send(mac.start(as: .macBook, .open, display: nil))
      #expect(granted.display == Fixture.standIn && granted.displays == [Fixture.standIn])

      try await mac.show([Fixture.hostVirtual], sharedAs: Fixture.hostVirtual)
      let swapped = await mac.send(mac.heartbeat(as: .macBook))
      #expect(swapped.display == Self.standInWhileVirtual && swapped.displays == [Self.standInWhileVirtual])
      #expect(await mac.capabilities(as: .iPhone).displays == [Self.standInWhileVirtual])

      try await mac.show([Fixture.standInAgain], sharedAs: Fixture.standInAgain)
      let back = await mac.send(mac.heartbeat(as: .macBook))
      #expect(back.display == Fixture.standIn && back.displays == [Fixture.standIn])

      let again = await mac.send(mac.start(as: .macBook, .attach, display: "stand-in"))
      #expect(again.status == "connecting" && again.display == Fixture.standIn)
      #expect(mac.host.current?.displayID == Fixture.displayID(of: Fixture.standInAgain))
    }
  }

  @Test func whenTheSharedDisplayIsUnpluggedAndTheHostFollowsToAnotherTheSessionReportsThatOne() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open, display: "side"))

      try await mac.show([Fixture.main], sharedAs: Fixture.main)

      let beat = await mac.send(mac.heartbeat(as: .macBook))
      #expect(beat.status == "connecting" && beat.display == Fixture.main && beat.displays == [Fixture.main])
    }
  }

  @Test func aDisplayMirroringTheVirtualOneIsReportedUnderItsOwnIDAtTheDesktopsNewSize() async throws {
    try await Fixture.run { mac in
      mac.displays = [Fixture.main, Fixture.side]
      _ = await mac.send(mac.start(as: .macBook, .open))

      try await mac.show([Fixture.hostVirtual, Fixture.side], sharedAs: Fixture.hostVirtual)

      let resized = ServerScreenSharingDisplay(id: "main", name: "Built-in Display", width: 3840, height: 2160)
      let beat = await mac.send(mac.heartbeat(as: .macBook))
      #expect(beat.display == resized && beat.displays == [resized, Fixture.side])
    }
  }
}
