#if os(macOS)
  import CodevisorClient
  import CodevisorTestSupport
  import Foundation
  import ScreenSharing
  import ScreenSharingConnection
  import ScreenSharingConnectionTesting
  import ScreenSharingTesting
  import Testing

  @MainActor
  @Suite("Screen share connection: VNC machines", .timeLimit(.minutes(1)))
  struct ScreenSharingVNCTransportTests {
    private static let screen = RFBRectangle(x: 0, y: 0, width: 64, height: 48)

    @Test("A VNC machine goes live on its first decoded update with no host session, and reconnects after a drop")
    func viewsAVNCMachine() async throws {
      let server = try await RFBLoopbackServer()
      defer { server.stop() }
      let port = server.port
      let host = FakeHost.old()
      host.provider = "vnc"
      host.displays = [ServerScreenSharingDisplay(id: "vnc:127.0.0.1:\(port)", name: "Loopback", width: 64, height: 48)]
      let harness = ConnectionHarness(host: host)
      harness.makeVNCTransport = { _, arbitratedByServer in
        ScreenSharingVNCTransport(
          open: { try await VNCConnection.open(host: "127.0.0.1", port: port, password: "secret") },
          arbitratedByServer: arbitratedByServer)
      }

      _ = harness.show()
      await awaitObserved { harness.connection.session != nil }
      let first = harness.connection.session
      #expect(harness.connection.display == host.displays[0])
      server.enqueue([.raw(Self.screen)])
      await harness.settle(.live)
      #expect(host.requests.map(\.operation) == [.capabilities])

      server.closeClient()
      await harness.settle(.reconnecting)
      await awaitObserved { harness.connection.session != nil && harness.connection.session !== first }
      server.enqueue([.raw(Self.screen)])
      await harness.settle(.live)

      #expect(host.starts.isEmpty && host.requests(.heartbeat).isEmpty)
    }
  }
#endif
