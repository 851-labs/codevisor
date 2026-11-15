import CodevisorClient
import CoreGraphics
import Foundation
import Testing

@testable import CodevisorCoreMac

struct ScreenSharingHostLogicalDisplaysTests {
  typealias Display = ScreenSharingHostLogicalDisplays.Display
  typealias Fixture = ScreenSharingHostOwnershipFixture

  private let main = Self.display(Fixture.main)
  private let side = Self.display(Fixture.side)
  private let virtual = Self.display(Fixture.hostVirtual)
  private let standIn = Self.display(Fixture.standIn)
  private let standInAgain = Self.display(Fixture.standInAgain)

  @Test func theHostsOwnVirtualDisplayIsNeverListedByItself() {
    var displays = ScreenSharingHostLogicalDisplays(kind: Fixture.kind)

    #expect(displays.list([virtual, main], shared: nil).map(\.description) == [Fixture.main])
    #expect(displays.list([virtual], shared: nil).isEmpty)
    #expect(displays.hasOnlyHostVirtual([virtual]))
    #expect(!displays.hasOnlyHostVirtual([virtual, main]) && !displays.hasOnlyHostVirtual([]))
  }

  @Test func aHeadlessMacsDisplayKeepsOneIDWhileTheVirtualDisplayReplacesItAndWhenItComesBack() {
    var displays = ScreenSharingHostLogicalDisplays(kind: Fixture.kind)
    #expect(displays.list([standIn], shared: nil).map(\.description) == [Fixture.standIn])

    let replaced = displays.list([virtual], shared: shared(Fixture.standIn, capturing: virtual, isStandIn: true))
    #expect(replaced.map(\.id) == [virtual.id])
    #expect(replaced.map(\.description) == [.init(id: "stand-in", name: "Display", width: 3840, height: 2160)])

    let back = displays.list([standInAgain], shared: nil)
    #expect(back.map(\.id) == [standInAgain.id])
    #expect(back.map(\.description) == [Fixture.standIn])
  }

  @Test func aMacWithTwoHeadlessDisplaysListsEachUnderItsOwnID() {
    var displays = ScreenSharingHostLogicalDisplays(kind: Fixture.kind)

    let both = displays.list([standIn, standInAgain], shared: nil)
    #expect(both.map(\.description.id) == ["stand-in", "stand-in-again"])

    let sharing = shared(Fixture.standIn, capturing: virtual, isStandIn: true)
    let swapped = displays.list([virtual, standInAgain], shared: sharing)
    #expect(Set(swapped.map(\.description.id)) == ["stand-in", "stand-in-again"] && swapped.count == 2)
  }

  @Test func aSessionStartedUnderALaterStandInIDIsStillListedUnderTheFirstOne() {
    var displays = ScreenSharingHostLogicalDisplays(kind: Fixture.kind)
    _ = displays.list([standIn], shared: nil)

    let listed = displays.list([virtual], shared: shared(Fixture.standInAgain, capturing: virtual, isStandIn: true))

    #expect(listed.map(\.description.id) == ["stand-in"])
  }

  @Test func aDisplayMirroringTheVirtualOneIsListedOnceUnderItsOwnIDAtTheDesktopsNewSize() {
    var displays = ScreenSharingHostLogicalDisplays(kind: Fixture.kind)
    let sharing = shared(Fixture.main, capturing: virtual, isStandIn: false)

    for available in [[virtual, main, side], [virtual, side], [main, virtual, side]] {
      let listed = displays.list(available, shared: sharing).map(\.description)
      #expect(Set(listed.map(\.id)) == ["main", "side"] && listed.count == 2)
      #expect(
        listed.first { $0.id == "main" } == .init(id: "main", name: "Built-in Display", width: 3840, height: 2160))
      #expect(listed.first { $0.id == "side" } == Fixture.side)
    }
  }

  @Test func aVirtualDisplayLeftOverFromAnEarlierSessionIsNotTakenForTheCurrentOne() {
    var displays = ScreenSharingHostLogicalDisplays(kind: Fixture.kind)
    let sharing = shared(Fixture.side, capturing: side, isStandIn: false)

    #expect(displays.list([virtual, main, side], shared: sharing).map(\.description) == [Fixture.main, Fixture.side])
  }

  private func shared(
    _ description: ServerScreenSharingDisplay, capturing: Display, isStandIn: Bool
  ) -> ScreenSharingHostLogicalDisplays.Shared {
    .init(description: description, capturing: capturing.id, isStandIn: isStandIn)
  }

  private static func display(_ description: ServerScreenSharingDisplay) -> Display {
    (Fixture.displayID(of: description), description)
  }
}
