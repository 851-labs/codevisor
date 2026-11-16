import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("Mac display picker on a machine's screen share connection", .timeLimit(.minutes(1)))
struct ScreenSharingDisplayPickerTests {
  private typealias Fixture = ScreenSharingConnectionsFixture
  private static let heartbeat: Duration = .seconds(8)

  private func liveTab() async throws -> (Fixture, RecordedSurface) {
    let host = FakeHost()
    host.displays = [FakeHost.display, FakeHost.second]
    let fixture = Fixture(host: host)
    let tab = fixture.surface(.tab)
    tab.surface.openedByUser()
    tab.show()
    try await fixture.goLive()
    await awaitObserved { tab.snapshot.endpoint != nil }
    await fixture.clock.waitForSleep(Self.heartbeat)
    return (fixture, tab)
  }

  private func savedDisplay(_ fixture: Fixture) -> String? {
    fixture.preferences.preferredDisplay(machineId: Fixture.machineId)
  }

  @Test("Picking a display keeps the session and control, and saves it once shown")
  func switchesWithoutReconnecting() async throws {
    let (fixture, tab) = try await liveTab()
    await awaitObserved { tab.snapshot.control?.phase == .requesting }
    let (endpoint, control) = (tab.snapshot.endpoint, tab.snapshot.control)
    fixture.host.hold(.heartbeat)

    tab.surface.switchDisplay(to: FakeHost.second.id)
    await awaitObserved { tab.snapshot.displaySwitch?.phase == .switching }
    #expect(savedDisplay(fixture) == nil, "nothing is saved before the host shows the display")
    fixture.host.release(.heartbeat)
    await awaitObserved { tab.snapshot.displaySwitch?.phase == .confirmed }

    #expect(tab.snapshot.displayId == FakeHost.second.id && savedDisplay(fixture) == FakeHost.second.id)
    #expect(tab.snapshot.connection == .live && tab.snapshot.endpoint == endpoint)
    #expect(tab.snapshot.control == control, "the control request in flight is not reset")
    #expect(fixture.host.starts.count == 1 && fixture.host.stops.isEmpty)
  }

  @Test("A display the host can't switch to leaves the current one, says why, and is saved only if it shows later")
  func keepsTheCurrentDisplayWhenTheHostCannotSwitch() async throws {
    let (fixture, tab) = try await liveTab()
    fixture.host.displaySwitchAnswer = .unavailable(message: "That display is asleep.")

    tab.surface.switchDisplay(to: FakeHost.second.id)
    await awaitObserved { tab.snapshot.displaySwitch?.phase == .unavailable(message: "That display is asleep.") }
    #expect(tab.snapshot.displayId == FakeHost.display.id && tab.snapshot.connection == .live)
    #expect(savedDisplay(fixture) == nil)

    fixture.host.shareDisplay(FakeHost.second.id)
    let answered = fixture.host.completed(.heartbeat)
    await fixture.clock.waitForSleep(Self.heartbeat)
    fixture.clock.advance(by: Self.heartbeat)
    await awaitObserved { tab.snapshot.displayId == FakeHost.second.id }

    #expect(fixture.host.completed(.heartbeat) > answered)
    #expect(tab.snapshot.displaySwitch?.phase == .confirmed && savedDisplay(fixture) == FakeHost.second.id)
  }
}
