import CodevisorTestSupport
import Foundation
import ScreenSharingTesting
import Testing

@testable import ScreenSharing

/// The `ScreenSharingViewingSession` contract, end to end, over a session with no transport: what
/// the viewer sees is a mailbox, two typed channels, transport state and a terminal close. Every
/// hop is drained explicitly, so ordering is observed rather than awaited.
@Suite @MainActor struct ScreenSharingViewingSessionTests {
  @Test func framesReachTheViewerNewestFirstAndEveryReplacementIsCounted() {
    let hop = ScreenSharingManualHop()
    let (session, host) = ScreenSharingLocalViewingSession.connected(hop: hop.schedule)
    let available = TestSignal()
    session.frames.onFrameAvailable { available.signal() }
    for identity in Int64(1)...3 { host.deliverFrame(identity: identity) }
    // A renderer that has not drained keeps the newest frame; the other two are counted, not queued.
    #expect(session.frames.take()?.timestampNs == 3)
    #expect(session.frames.droppedFrames == 2)
    #expect(session.frames.take() == nil)
    // Only the empty-to-full transition wakes the renderer, so three frames are one notification.
    #expect(available.value == 1)
    host.deliverFrame(identity: 4)
    #expect(available.value == 2)
    #expect(session.metrics.snapshot().counters["viewingSessionFrames"] == 4)
  }

  @Test func aControlRequestAndItsGrantTravelInOrderAndNeverReentrantly() throws {
    let hop = ScreenSharingManualHop()
    let (session, host) = ScreenSharingLocalViewingSession.connected(hop: hop.schedule)
    #expect(session.capabilities.contains(.control))
    let control = try #require(session.control)
    let peer = try #require(host.control)
    let request = UUID()
    let lease = UUID()
    var hostReceived: [ScreenSharingControlMessage] = []
    var viewerReceived: [ScreenSharingControlMessage] = []
    peer.onMessage = { message in
      hostReceived.append(message)
      guard case .request = message else { return }
      // A reply from inside delivery is queued behind this drain, never delivered inline.
      #expect(peer.send(.grant(request: request, lease: lease)))
      #expect(viewerReceived.isEmpty)
    }
    control.onMessage = { viewerReceived.append($0) }
    #expect(control.send(.request(id: request)))
    #expect(hostReceived.isEmpty)
    hop.drain()
    #expect(hostReceived == [.request(id: request)])
    hop.drain()
    #expect(viewerReceived == [.grant(request: request, lease: lease)])

    // Input rides the same channel behind the lease, in the order it was sent.
    let events: [ScreenSharingControlMessage] = (1...3).map {
      .input(
        lease: lease, sequence: UInt64($0), event: .key(code: UInt16($0), down: true, repeatKey: false, modifiers: 0))
    }
    for event in events { #expect(control.send(event)) }
    hop.drain()
    #expect(hostReceived == [.request(id: request)] + events)
  }

  @Test func aTerminalMediaFailureIsRecordedOnceAndIsSeparateFromTransportState() {
    let (session, host) = ScreenSharingLocalViewingSession.connected()
    var states: [String] = []
    session.onConnectionChanged = { states.append($0) }
    #expect(session.failure == nil)
    host.report(connection: "connected")
    host.fail("The hardware decoder stopped.")
    // A media failure is not a transport state change, and the first one is the one that stands.
    host.fail("A later failure.")
    host.report(connection: "disconnected")
    #expect(session.failure == "The hardware decoder stopped.")
    #expect(states == ["connected", "disconnected"])
  }

  @Test func closeIsTerminalAndIdempotent() async throws {
    let hop = ScreenSharingManualHop()
    let (session, host) = ScreenSharingLocalViewingSession.connected(hop: hop.schedule)
    host.publish(statistics: ["bytesReceived": "1024"])
    let control = try #require(session.control)
    var states: [String] = []
    var viewerReceived: [ScreenSharingControlMessage] = []
    session.onConnectionChanged = { states.append($0) }
    control.onMessage = { viewerReceived.append($0) }
    host.deliverFrame(identity: 1)
    #expect(await session.statistics() == ["bytesReceived": "1024"])
    // A message already in flight when the session closes must never be delivered late.
    #expect(try #require(host.control).send(.heartbeat(lease: UUID())))

    session.close()
    session.close()

    #expect(!session.frames.isHolding)
    #expect(!control.isAvailable)
    #expect(!control.send(.request(id: UUID())))
    #expect(await session.statistics().isEmpty)
    hop.drainAll()
    #expect(viewerReceived.isEmpty)
    host.deliverFrame(identity: 2)
    host.report(connection: "failed")
    host.fail("too late")
    hop.drainAll()
    #expect(!session.frames.isHolding)
    #expect(states.isEmpty)
    #expect(session.failure == nil)
  }

  @Test func aBackendThatNegotiatedNothingOffersNoChannelsAndNoStatistics() async {
    let (session, host) = ScreenSharingLocalViewingSession.connected(capabilities: [])
    #expect(session.control == nil)
    #expect(session.clipboard == nil)
    #expect(host.control == nil)
    host.publish(statistics: ["bytesReceived": "1024"])
    #expect(await session.statistics().isEmpty)
    // Frames do not depend on a capability: a session that negotiated nothing still shows a screen.
    host.deliverFrame(identity: 1)
    #expect(session.frames.take()?.timestampNs == 1)
  }

  @Test func replacingAClosedSessionLeavesTheClosedOneClosed() throws {
    let hop = ScreenSharingManualHop()
    let (first, firstHost) = ScreenSharingLocalViewingSession.connected(hop: hop.schedule)
    first.close()
    let (second, secondHost) = ScreenSharingLocalViewingSession.connected(hop: hop.schedule)
    var received: [ScreenSharingControlMessage] = []
    try #require(second.control).onMessage = { received.append($0) }
    let lease = UUID()
    #expect(try #require(secondHost.control).send(.revoked(lease: lease, reason: "taken back")))
    firstHost.deliverFrame(identity: 1)
    hop.drainAll()
    #expect(received == [.revoked(lease: lease, reason: "taken back")])
    #expect(!first.frames.isHolding)
    #expect(second.frames.take() == nil)
  }

  /// The clipboard protocol over the session's own channel: a chunked transfer completes through
  /// the hop, and a transfer nobody answers ends exactly at its ten-second deadline. The deadline
  /// is the only thing here that depends on time, so it is the only thing driven by the clock.
  @Test func aChunkedClipboardTransferCompletesOverTheSessionChannelAndTimesOutAtItsDeadline() throws {
    let hop = ScreenSharingManualHop()
    let (session, host) = ScreenSharingLocalViewingSession.connected(hop: hop.schedule)
    let clock = TestClock()
    let origin = clock.now
    let elapsed: @Sendable () -> TimeInterval = {
      let parts = origin.duration(to: clock.now).components
      return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
    let viewerChannel = try #require(session.clipboard)
    let hostChannel = try #require(host.clipboard)
    var hostText = "remote"
    var viewerText = "local"
    var viewerResults: [String?] = []

    let hostTransfer = ScreenSharingClipboardTransfer(
      send: { hostChannel.send($0) }, now: elapsed, canReceiveUnsolicited: { true },
      read: { hostText }, write: { hostText = $0 })
    let viewerTransfer = ScreenSharingClipboardTransfer(
      send: { viewerChannel.send($0) }, now: elapsed, canReceiveUnsolicited: { false },
      read: { viewerText }, write: { viewerText = $0 })
    viewerTransfer.onFinished = { viewerResults.append($0) }
    hostChannel.onMessage = { hostTransfer.receive($0) }
    viewerChannel.onMessage = { viewerTransfer.receive($0) }

    // Larger than one 2 KiB chunk, so the stop-and-wait acknowledgment loop runs over the channel.
    let text = String(repeating: "é👩🏽‍💻日本語\n", count: 400)
    viewerTransfer.sendText(text)
    #expect(viewerTransfer.isBusy)
    hop.drainAll()
    #expect(hostText == text)
    #expect(viewerResults == [nil])
    #expect(!viewerTransfer.isBusy && !hostTransfer.isBusy)

    // A request whose answer never arrives: nothing expires early, and the deadline ends it.
    viewerChannel.onMessage = { _ in }
    viewerTransfer.requestText()
    hop.drainAll()
    clock.advance(by: .milliseconds(9999))
    viewerTransfer.tick()
    #expect(viewerTransfer.isBusy)
    clock.advance(by: .milliseconds(1))
    viewerTransfer.tick()
    #expect(!viewerTransfer.isBusy)
    #expect(viewerResults.last == "Clipboard transfer timed out. Try again.")
    #expect(viewerText == "local")
  }
}
