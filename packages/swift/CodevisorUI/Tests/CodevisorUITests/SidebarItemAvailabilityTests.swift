import Testing
@testable import CodevisorUI

struct SidebarItemAvailabilityTests {
  @Test func aListedItemOnAConnectedMachineIsAvailable() {
    #expect(SidebarItemAvailability(.listed, on: .reachable) == .available)
    #expect(SidebarItemAvailability(.listed, on: .connecting) == .available)
  }

  @Test func archivedItemsAreGone() {
    #expect(SidebarItemAvailability(.hidden, on: .reachable) == .gone)
    #expect(SidebarItemAvailability(.hidden, on: .connecting) == .gone)
  }

  @Test func itemsOnAnUnknownOrOfflineMachineAreGoneEvenWhenCached() {
    #expect(SidebarItemAvailability(.listed, on: .unknown) == .gone)
    #expect(SidebarItemAvailability(.listed, on: .unreachable) == .gone)
    #expect(SidebarItemAvailability(.missing, on: .unreachable) == .gone)
  }

  @Test func aMissingItemWaitsForItsMachineToFinishSyncing() {
    #expect(SidebarItemAvailability(.missing, on: .connecting) == .pending)
    #expect(SidebarItemAvailability(.missing, on: .reachable) == .gone)
  }
}
