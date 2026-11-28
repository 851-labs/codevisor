import CodevisorClient
import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import ScreenSharingTesting
import Testing

@MainActor
@Suite("Screen share connection: switching display on a live VNC connection", .timeLimit(.minutes(1)))
struct ScreenSharingVNCDisplaySwitchTests {
  @MainActor
  @Observable
  final class OpenedDisplays {
    var ids: [String] = []
  }

  private typealias Switch = ScreenSharingDisplaySwitch

  nonisolated private static let closedPort: UInt16 = 1

  nonisolated private static let desktop = ServerScreenSharingDisplay(
    id: "vnc:desktop", name: "Desktop", width: 64, height: 48)
  nonisolated private static let screen = ServerScreenSharingDisplay(
    id: "vnc:screen", name: "Screen", width: 64, height: 48)

  private func linuxMachine(
    port: UInt16, displays: [ServerScreenSharingDisplay] = [desktop, screen],
    unavailable: [ServerScreenSharingUnavailableDisplay]? = nil, unreachable: Set<String> = []
  ) -> (ConnectionHarness, OpenedDisplays) {
    let host = FakeHost(abilities: [])
    host.provider = "vnc"
    host.displays = displays
    host.unavailable = unavailable
    let harness = ConnectionHarness(host: host)
    let opened = OpenedDisplays()
    harness.makeVNCTransport = { displayId, arbitratedByServer in
      opened.ids.append(displayId)
      let reached = unreachable.contains(displayId) ? Self.closedPort : port
      return ScreenSharingVNCTransport(
        open: { try await VNCConnection.open(host: "127.0.0.1", port: reached, password: "secret") },
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
    #expect(connection.displaySwitch == Switch(displayId: Self.screen.id, name: Self.screen.name, phase: .switching))
    await awaitObserved { connection.state == .live && connection.display == Self.screen }

    #expect(opened.ids == [Self.desktop.id, Self.screen.id])
    #expect(connection.displaySwitch == Switch(displayId: Self.screen.id, name: Self.screen.name, phase: .confirmed))
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

    #expect(
      connection.displaySwitch
        == Switch(displayId: Self.screen.id, name: Self.screen.name, phase: .unavailable(message: why)))
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

    #expect(connection.displaySwitch == Switch(displayId: Self.desktop.id, name: Self.desktop.name, phase: .confirmed))
    #expect(connection.display == Self.desktop && opened.ids.last == Self.desktop.id)
  }

  @Test("A picked display that fails to open is reported at once, and the display shown before comes back")
  func returnsToTheDisplayShownBefore() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let (harness, opened) = linuxMachine(port: server.port, unreachable: [Self.screen.id])
    let connection = harness.connection
    _ = harness.show()
    await awaitObserved { connection.state == .live }

    connection.switchDisplay(to: Self.screen.id)
    await awaitObserved { connection.displaySwitch?.phase != .switching && connection.state == .live }

    let failed = Switch(displayId: Self.screen.id, name: Self.screen.name, phase: .unavailable(message: nil))
    #expect(connection.displaySwitch == failed && failed.failure == "Couldn't switch to Screen.")
    #expect(connection.display == Self.desktop && connection.preferredDisplayId == nil)
    #expect(opened.ids == [Self.desktop.id, Self.screen.id, Self.desktop.id])
  }

  @Test("A pick while the connection is still coming up opens the picked display, and isn't saved before it shows")
  func picksWhileConnecting() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.sendsFramebuffer = false
    let server = try await RFBLoopbackServer(configuration: configuration)
    defer { server.stop() }
    let (harness, opened) = linuxMachine(port: server.port)
    let connection = harness.connection
    _ = harness.show()
    await awaitObserved { connection.session != nil }

    connection.switchDisplay(to: Self.screen.id)
    await awaitObserved { opened.ids.count == 2 }

    #expect(opened.ids == [Self.desktop.id, Self.screen.id])
    #expect(connection.displaySwitch?.phase == .switching && connection.preferredDisplayId == nil)
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
