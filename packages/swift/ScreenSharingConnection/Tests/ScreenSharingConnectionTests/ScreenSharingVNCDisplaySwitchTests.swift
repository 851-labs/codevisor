import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import ScreenSharingTesting
import Testing

@MainActor
@Suite("Screen share connection: switching display on a live VNC connection", .timeLimit(.minutes(1)))
struct ScreenSharingVNCDisplaySwitchTests {
  @MainActor
  private final class OpenedDisplays {
    var ids: [String] = []
  }

  private typealias Switch = ScreenSharingDisplaySwitch

  nonisolated private static let desktop = ServerScreenSharingDisplay(
    id: "vnc:desktop", name: "Desktop", width: 64, height: 48)
  nonisolated private static let screen = ServerScreenSharingDisplay(
    id: "vnc:screen", name: "Screen", width: 64, height: 48)

  private func linuxMachine(
    port: UInt16, displays: [ServerScreenSharingDisplay] = [desktop, screen],
    unavailable: [ServerScreenSharingUnavailableDisplay]? = nil
  ) -> (ConnectionHarness, OpenedDisplays) {
    let host = FakeHost(abilities: [])
    host.provider = "vnc"
    host.displays = displays
    host.unavailable = unavailable
    let harness = ConnectionHarness(host: host)
    let opened = OpenedDisplays()
    harness.makeVNCTransport = { displayId, arbitratedByServer in
      opened.ids.append(displayId)
      return ScreenSharingVNCTransport(
        open: { try await VNCConnection.open(host: "127.0.0.1", port: port, password: "secret") },
        arbitratedByServer: arbitratedByServer)
    }
    return (harness, opened)
  }

  @Test("Picking another display reconnects to it at once, and the choice is kept")
  func reconnectsToThePickedDisplay() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let (harness, opened) = linuxMachine(port: server.port)
    let connection = harness.connection
    _ = harness.show()
    await awaitObserved { connection.state == .live }

    connection.switchDisplay(to: Self.screen.id)
    #expect(connection.displaySwitch == Switch(displayId: Self.screen.id, phase: .switching))
    await awaitObserved { connection.state == .live && connection.display == Self.screen }

    #expect(opened.ids == [Self.desktop.id, Self.screen.id])
    #expect(connection.displaySwitch == Switch(displayId: Self.screen.id, phase: .confirmed))
    #expect(connection.preferredDisplayId == Self.screen.id)
  }

  @Test("Picking the display already shown doesn't reconnect")
  func keepsTheShownDisplay() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let (harness, opened) = linuxMachine(port: server.port)
    let connection = harness.connection
    _ = harness.show()
    await awaitObserved { connection.state == .live }

    connection.switchDisplay(to: Self.desktop.id)

    #expect(connection.state == .live && connection.displaySwitch == nil)
    #expect(opened.ids == [Self.desktop.id])
  }

  @Test("A picked display the machine no longer offers is reported with its reason, and isn't saved")
  func reportsAPickTheMachineNoLongerOffers() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let (harness, opened) = linuxMachine(port: server.port)
    let connection = harness.connection
    _ = harness.show()
    await awaitObserved { connection.state == .live }
    let why = "This machine's screen isn't being shared right now."
    harness.host.displays = [Self.desktop]
    harness.host.unavailable = [ServerScreenSharingUnavailableDisplay(id: Self.screen.id, name: "Screen", problem: why)]

    connection.switchDisplay(to: Self.screen.id)
    await awaitObserved { connection.displaySwitch?.phase != .switching && connection.state == .live }

    #expect(connection.displaySwitch == Switch(displayId: Self.screen.id, phase: .unavailable(message: why)))
    #expect(connection.display == Self.desktop && connection.preferredDisplayId == nil)
    #expect(opened.ids == [Self.desktop.id, Self.desktop.id])
  }

  @Test("A second pick while the first one is still reconnecting wins, with no error for the first")
  func aSecondPickWins() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let (harness, opened) = linuxMachine(port: server.port)
    let connection = harness.connection
    _ = harness.show()
    await awaitObserved { connection.state == .live }

    connection.switchDisplay(to: Self.screen.id)
    connection.switchDisplay(to: Self.desktop.id)
    await awaitObserved { connection.displaySwitch?.phase != .switching && connection.state == .live }

    #expect(connection.displaySwitch == Switch(displayId: Self.desktop.id, phase: .confirmed))
    #expect(connection.display == Self.desktop && opened.ids.last == Self.desktop.id)
  }

  @Test("The displays the machine can't share are kept with the reason it gives")
  func keepsWhyADisplayIsUnavailable() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let missing = ServerScreenSharingUnavailableDisplay(
      id: "vnc:desktop", name: "Desktop", problem: "The desktop on this machine isn't running.")
    let (harness, _) = linuxMachine(port: server.port, displays: [Self.screen], unavailable: [missing])
    _ = harness.show()
    await awaitObserved { harness.connection.state == .live }

    #expect(harness.connection.displays == [Self.screen])
    #expect(harness.connection.unavailableDisplays == [missing])
    #expect(missing.summary == "Desktop: The desktop on this machine isn't running.")
  }
}
