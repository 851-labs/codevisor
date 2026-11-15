import CodevisorTestSupport
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("The endpoint keeps a control lease alive off the main thread", .timeLimit(.minutes(1)))
struct ScreenSharingEndpointHeartbeatTests {
  @Test("A lease taken over a channel that can send from any thread is kept alive without the main thread")
  func keepsALeaseAliveInTheBackground() async {
    let session = FakeMediaSession(capabilities: [.control])
    session.controlChannel.isAvailable = true
    let endpoint = ScreenSharingViewerEndpoint(session: session, surface: FakeSurface())
    defer { endpoint.close() }
    let lease = UUID()

    #expect(endpoint.beginInput(lease: lease) == nil)
    await session.controlChannel.sentInBackground.wait()

    #expect(session.controlChannel.backgroundSent.withLock { $0.first } == .heartbeat(lease: lease))
    #expect(endpoint.sendControl(.heartbeat(lease: lease)), "the main-thread tick reports the channel as open")
    #expect(session.controlChannel.sent.isEmpty, "and puts no second heartbeat on the wire")
  }
}
