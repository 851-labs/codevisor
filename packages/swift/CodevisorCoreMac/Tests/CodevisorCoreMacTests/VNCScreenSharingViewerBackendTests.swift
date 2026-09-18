import CodevisorClient
import CodevisorCore
import ScreenSharing
import CodevisorTestSupport
import CustomDump
import Foundation
import ScreenSharingTesting
import Testing
@testable import CodevisorCoreMac

/// The VNC backend against the loopback server with the real client:
/// discovery, the ready signal, replacement after a lost socket, and the
/// terminal messages.
@MainActor
struct VNCScreenSharingViewerBackendTests {
  @MainActor
  final class Harness {
    let server: RFBLoopbackServer
    let log = ScreenSharingEventLog()
    private(set) var surfaces: [FakeSurface] = []
    private(set) var backend: ScreenSharingViewerBackend!
    private var consumers: [Task<Void, Never>] = []

    init(configuration: RFBLoopbackServer.Configuration = .init(), password: String? = "secret") async throws {
      server = try await RFBLoopbackServer(configuration: configuration)
      let port = server.port
      backend = .vnc(
        displayId: "vnc:127.0.0.1:\(port)",
        open: { try await VNCConnection.open(host: "127.0.0.1", port: port, password: password) },
        makeSurface: { [self] _ in
          let surface = FakeSurface()
          surfaces.append(surface)
          return surface
        })
    }

    func connect() {
      let backend = backend!, log = log
      consumers.append(
        Task { @MainActor in
          for await event in await backend.connect("vnc") { log.append(event) }
          log.finish()
        })
    }

    func cancelConsumers() async {
      for consumer in consumers { consumer.cancel() }
      for consumer in consumers { await consumer.value }
    }

    func stop() { server.stop() }
  }

  @Test func discoveryReportsTheDesktopFromTheHandshake() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let displays = try await harness.backend.discover()
    #expect(
      displays == [
        ServerScreenSharingDisplay(id: "vnc:127.0.0.1:\(harness.server.port)", name: "Loopback", width: 64, height: 48)
      ])
    let wrong = try await Harness(password: "wrong")
    defer { wrong.stop() }
    await #expect(throws: RFBError.authenticationFailed("Authentication failed")) { try await wrong.backend.discover() }
  }

  @Test func readyAfterTheFirstFrameAndReplacementAfterALostSocket() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    harness.connect()
    await awaitObserved { harness.log.endpoints.count == 1 || harness.log.finished == 1 }
    try #require(harness.log.endpoints.count == 1)
    let first = harness.log.endpoints[0]
    expectNoDifference(harness.log.events, [.opened(first)])
    #expect(first.supportsControl && first.supportsClipboard)
    harness.surfaces[0].present()
    await awaitObserved { harness.log.events.count >= 2 }
    harness.server.closeClient()
    await awaitObserved { harness.log.endpoints.count == 2 || harness.log.finished == 1 }
    try #require(harness.log.endpoints.count == 2)
    let second = harness.log.endpoints[1]
    expectNoDifference(harness.log.events, [.opened(first), .ready, .reconnecting, .opened(second)])
    #expect((first.session as? VNCScreenSharingSession)?.closed == true)
    #expect(harness.surfaces[0].stopped && !harness.surfaces[1].stopped)
    await harness.cancelConsumers()
    #expect(harness.log.finished == 1)
    #expect((second.session as? VNCScreenSharingSession)?.closed == true && harness.surfaces[1].stopped)
  }

  @Test func lossBeforeVideoAndBadCredentialsEndWithTheReason() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    harness.connect()
    await awaitObserved { harness.log.endpoints.count == 1 || harness.log.finished == 1 }
    try #require(harness.log.endpoints.count == 1)
    harness.server.closeClient()
    await awaitObserved { harness.log.finished == 1 }
    expectNoDifference(harness.log.events.dropFirst(), [.ended("The VNC server closed the connection.")])

    let wrong = try await Harness(password: "wrong")
    defer { wrong.stop() }
    wrong.connect()
    await awaitObserved { wrong.log.finished == 1 }
    expectNoDifference(wrong.log.events, [.ended("Authentication failed")])
    #expect(wrong.surfaces.isEmpty)
  }

  @Test func aRefusedConnectionEndsWithAReadableMessage() async throws {
    // A privileged port nothing listens on: a stopped loopback server's ephemeral port could be
    // reused by another test's server while this one connects.
    let backend = ScreenSharingViewerBackend.vnc(
      displayId: "vnc:127.0.0.1:1",
      open: { try await VNCConnection.open(host: "127.0.0.1", port: 1, password: nil) },
      makeSurface: { _ in FakeSurface() })
    let log = ScreenSharingEventLog()
    for await event in await backend.connect("vnc") { log.append(event) }
    expectNoDifference(log.events, [.ended("The VNC server refused the connection.")])
  }
}
