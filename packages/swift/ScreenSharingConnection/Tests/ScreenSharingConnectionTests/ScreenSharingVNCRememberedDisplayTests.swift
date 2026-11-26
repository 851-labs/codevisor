import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import ScreenSharingTesting
import Testing

@MainActor
@Suite("Screen share connection: a remembered VNC display", .timeLimit(.minutes(1)))
struct ScreenSharingVNCRememberedDisplayTests {
  @MainActor
  private final class OpenedDisplays {
    var ids: [String] = []
  }

  @Test("A viewer that remembers a display the machine no longer offers opens the one it does offer")
  func opensTheOfferedDisplay() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let port = server.port
    let host = FakeHost(abilities: [])
    host.provider = "vnc"
    host.displays = [ServerScreenSharingDisplay(id: "vnc:desktop", name: "Desktop", width: 64, height: 48)]
    let harness = ConnectionHarness(host: host)
    let opened = OpenedDisplays()
    harness.makeVNCTransport = { displayId, arbitratedByServer in
      opened.ids.append(displayId)
      return ScreenSharingVNCTransport(
        open: { try await VNCConnection.open(host: "127.0.0.1", port: port, password: "secret") },
        arbitratedByServer: arbitratedByServer)
    }
    harness.connection.preferredDisplayId = "vnc:5901"

    _ = harness.show()
    await awaitObserved { harness.connection.session != nil }

    #expect(opened.ids == ["vnc:desktop"])
    #expect(harness.connection.display?.id == "vnc:desktop")
  }
}
