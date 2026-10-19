import CodevisorTestSupport
import Foundation
import ScreenSharingTesting
import Testing

@testable import ScreenSharing

@Suite @MainActor struct ScreenSharingViewingSessionTests {
  @Test func framesReachTheViewerNewestFirstAndEveryReplacementIsCounted() {
    let hop = ScreenSharingManualHop()
    let (session, host) = ScreenSharingLocalViewingSession.connected(hop: hop.schedule)
    let available = TestSignal()
    session.frames.onFrameAvailable { available.signal() }
    for identity in Int64(1)...3 { host.deliverFrame(identity: identity) }
    #expect(session.frames.take()?.timestampNs == 3)
    #expect(session.frames.droppedFrames == 2)
    #expect(session.frames.take() == nil)
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
      read: { _ in .init(text: hostText) }, write: { hostText = $0.text ?? "" })
    let viewerTransfer = ScreenSharingClipboardTransfer(
      send: { viewerChannel.send($0) }, now: elapsed, canReceiveUnsolicited: { false },
      read: { _ in .init(text: viewerText) }, write: { viewerText = $0.text ?? "" })
    viewerTransfer.onFinished = { viewerResults.append($0) }
    hostChannel.onMessage = { hostTransfer.receive($0) }
    viewerChannel.onMessage = { viewerTransfer.receive($0) }

    let text = String(repeating: "é👩🏽‍💻日本語\n", count: 400)
    viewerTransfer.sendContent(.init(text: text))
    #expect(viewerTransfer.isBusy)
    hop.drainAll()
    #expect(hostText == text)
    #expect(viewerResults == [nil])
    #expect(!viewerTransfer.isBusy && !hostTransfer.isBusy)

    viewerChannel.onMessage = { _ in }
    viewerTransfer.requestContent()
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
