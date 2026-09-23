import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// ExtendedDesktopSize (-308), 851-2314: the remote desktop follows the
/// viewer's size, debounced, and falls back to scaling when refused.
@MainActor
struct VNCDesktopResizeTests {
  typealias Harness = RFBClientLoopbackTests.Harness

  static func server(_ resize: RFBLoopbackServer.Configuration.DesktopResize) -> RFBLoopbackServer.Configuration {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.desktopResize = resize
    return configuration
  }

  // MARK: L1

  @Test func setDesktopSizeHasItsRegisteredLayout() async throws {
    let message = RFBClientMessage.setDesktopSize(
      width: 800, height: 600, screens: [RFBScreen(id: 7, x: 0, y: 0, width: 800, height: 600)])
    #expect(message.encoded == [251, 0, 3, 32, 2, 88, 1, 0, 0, 0, 0, 7, 0, 0, 0, 0, 3, 32, 2, 88, 0, 0, 0, 0])
    let stream = RFBInputStream(transport: ScriptedTransport(message.encoded))
    #expect(try await RFBClientMessage.read(from: stream) == message)
  }

  // MARK: L2 — client

  @Test func theServerAnnouncesItsLayoutAndAcceptsAResize() async throws {
    let harness = try await Harness(configuration: Self.server(.accept))
    defer { harness.stop() }
    let first = try #require(await harness.nextUpdate())
    #expect(first.update.desktopSize?.reason == .server)
    #expect(first.update.desktopSize?.screens.first?.width == 64)
    try await harness.client.send(
      .setDesktopSize(width: 100, height: 70, screens: [RFBScreen(id: 1, x: 0, y: 0, width: 100, height: 70)]))
    let resized = try #require(await harness.nextUpdate())
    #expect(resized.update.desktopSize?.reason == .thisClient && resized.update.desktopSize?.status == .ok)
    #expect(resized.update.resized)
    #expect((resized.width, resized.height) == (100, 70))
  }

  @Test func aRefusalLeavesTheFramebufferAlone() async throws {
    let harness = try await Harness(configuration: Self.server(.refuse))
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    try await harness.client.send(.setDesktopSize(width: 100, height: 70, screens: []))
    let answer = try #require(await harness.nextUpdate())
    #expect(answer.update.desktopSize?.status == .prohibited)
    #expect(!answer.update.resized && (answer.width, answer.height) == (64, 48))
  }

  // MARK: L2 — session, debounced on a test clock

  final class Session {
    let server: RFBLoopbackServer
    let session: VNCScreenSharingSession
    let clock = TestClock()
    @MainActor init(_ resize: RFBLoopbackServer.Configuration.DesktopResize) async throws {
      server = try await RFBLoopbackServer(configuration: VNCDesktopResizeTests.server(resize))
      let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
      let outcome = try await client.connect(password: "secret")
      let clock = clock
      session = VNCScreenSharingSession(
        client: client, parameters: outcome.parameters, sleep: { try await clock.sleep(for: $0) })
    }
    @MainActor func stop() {
      session.close()
      server.stop()
    }
    var resizeRequests: [RFBClientMessage] {
      server.received.filter { if case .setDesktopSize = $0 { true } else { false } }
    }
  }

  @Test func aBurstOfSizesSendsOneRequestForTheLastAfterTheDebounce() async throws {
    let harness = try await Session(.accept)
    defer { harness.stop() }
    #expect(await awaitPolled { harness.session.metrics.snapshot().counters["vncUpdatesPublished"] == 1 })
    harness.session.requestDesktopSize(width: 700, height: 500)
    harness.session.requestDesktopSize(width: 900, height: 600)
    // The second call cancels the first debounce (before or after it starts sleeping): one stays pending.
    await harness.clock.waitForSleep(VNCScreenSharingSession.resizeDebounce)
    #expect(harness.clock.pendingCount == 1)
    harness.clock.advance(by: .milliseconds(399))
    #expect(harness.resizeRequests.isEmpty, "Nothing before the size has held for the debounce.")
    harness.clock.advance(by: .milliseconds(1))
    #expect(await awaitPolled { harness.server.framebuffer.width == 900 && harness.server.framebuffer.height == 600 })
    #expect(harness.resizeRequests.count == 1)
    #expect(await awaitPolled { harness.session.metrics.snapshot().labels["videoSize"] == "900 × 600" })
  }

  @Test func aRefusedServerIsNotAskedAgain() async throws {
    let harness = try await Session(.refuse)
    defer { harness.stop() }
    #expect(await awaitPolled { harness.session.metrics.snapshot().counters["vncUpdatesPublished"] == 1 })
    harness.session.requestDesktopSize(width: 700, height: 500)
    await harness.clock.waitForSleep(VNCScreenSharingSession.resizeDebounce)
    harness.clock.advance(by: VNCScreenSharingSession.resizeDebounce)
    #expect(await awaitPolled { harness.session.metrics.snapshot().labels["vncResize"] != nil })
    harness.session.requestDesktopSize(width: 800, height: 500)
    await harness.clock.waitForSleep(VNCScreenSharingSession.resizeDebounce, count: 2)
    harness.clock.advance(by: VNCScreenSharingSession.resizeDebounce)
    #expect(harness.session.metrics.snapshot().counters["vncResizeRequests"] == 1)
  }

  @Test func aServerWithoutItIsNeverAsked() async throws {
    let harness = try await Session(.unsupported)
    defer { harness.stop() }
    #expect(await awaitPolled { harness.session.metrics.snapshot().counters["vncUpdatesPublished"] == 1 })
    harness.session.requestDesktopSize(width: 700, height: 500)
    await harness.clock.waitForSleep(VNCScreenSharingSession.resizeDebounce)
    harness.clock.advance(by: VNCScreenSharingSession.resizeDebounce)
    #expect(harness.session.metrics.snapshot().counters["vncResizeRequests"] == nil)
    #expect(harness.resizeRequests.isEmpty)
  }

  @Test func sizesAreClampedToAUsableRange() async throws {
    let harness = try await Session(.accept)
    defer { harness.stop() }
    #expect(await awaitPolled { harness.session.metrics.snapshot().counters["vncUpdatesPublished"] == 1 })
    harness.session.requestDesktopSize(width: 10, height: 10)
    await harness.clock.waitForSleep(VNCScreenSharingSession.resizeDebounce)
    harness.clock.advance(by: VNCScreenSharingSession.resizeDebounce)
    #expect(await awaitPolled { harness.server.framebuffer.width == 320 && harness.server.framebuffer.height == 240 })
  }
}
