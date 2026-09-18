import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

/// A real sender and a real receiver negotiated against each other inside this
/// process. The SDP is handed over in memory, so no signalling server exists;
/// candidates ride inside the descriptions because `makeDescription` waits for
/// gathering to complete, so nothing is trickled either. With no ICE servers
/// configured the agents only ever see host candidates on the loopback
/// interface and the OS picks every port. Every wait below is a delegate
/// callback counted by a `TestSignal`, never a sleep or a poll.
@MainActor
struct ScreenSharingPeerLoopbackTests {
  /// Both ends plus the callbacks a test synchronises on. Callbacks are
  /// installed before any description is produced, so no event can be missed
  /// between construction and the first wait.
  @MainActor
  final class Harness {
    let hostMetrics = ScreenSharingMetrics()
    let viewerMetrics = ScreenSharingMetrics()
    let sender: ScreenSharingSender
    let receiver: ScreenSharingReceiver
    let hostConnected = TestSignal()
    let viewerConnected = TestSignal()
    let hostControlOpened = TestSignal()
    let viewerControlOpened = TestSignal()
    let viewerControlDelivered = TestSignal()
    let hostControlDelivered = TestSignal()
    private(set) var hostConnectionStates: [String] = []
    private(set) var hostControlAvailability: [Bool] = []
    private(set) var viewerReceived: [ScreenSharingControlMessage] = []
    private(set) var hostReceived: [ScreenSharingControlMessage] = []

    init(width: Int = 128, height: Int = 64) throws {
      let configuration = try ScreenSharingVideoConfiguration(width: width, height: height)
      sender = try ScreenSharingSender(configuration: configuration, metrics: hostMetrics)
      receiver = try ScreenSharingReceiver(configuration: configuration, metrics: viewerMetrics)
      sender.onConnectionChanged = { [self] state in
        hostConnectionStates.append(state)
        if state == "connected" { hostConnected.signal() }
      }
      receiver.onConnectionChanged = { [self] state in
        if state == "connected" { viewerConnected.signal() }
      }
      sender.controlChannel.onAvailabilityChanged = { [self] available in
        hostControlAvailability.append(available)
        if available { hostControlOpened.signal() }
      }
      receiver.controlChannel.onAvailabilityChanged = { [self] available in
        if available { viewerControlOpened.signal() }
      }
      receiver.controlChannel.onMessage = { [self] message in
        viewerReceived.append(message)
        viewerControlDelivered.signal()
      }
      sender.controlChannel.onMessage = { [self] message in
        hostReceived.append(message)
        hostControlDelivered.signal()
      }
    }

    /// The viewer offers: its recvOnly video m-line is what the host's
    /// sendOnly track associates with when the host answers.
    func negotiate() async throws {
      let offer = try await receiver.makeDescription(offer: true)
      #expect(offer.kind == "offer" && offer.version == 1)
      try await sender.accept(offer)
      let answer = try await sender.makeDescription(offer: false)
      #expect(answer.kind == "answer")
      try await receiver.accept(answer)
    }

    func close() {
      sender.close()
      receiver.close()
    }

    func awaitClosed() async {
      await sender.awaitClosed()
      await receiver.awaitClosed()
    }
  }

  @Test func negotiationConnectsBothEndsAndHandsTheRemoteVideoTrackToTheViewer() async throws {
    let harness = try Harness()
    defer { harness.close() }
    try await harness.negotiate()
    // The viewer's receiver and its video track exist as soon as the answer has
    // been applied: libwebrtc creates them while setting the remote description.
    let tracks = harness.receiver.connection.receivers.compactMap { $0.track }
    #expect(tracks.count == 1 && tracks[0].kind == "video")
    #expect(harness.sender.connection.transceivers.contains { $0.direction == .sendOnly })
    await harness.hostConnected.wait()
    await harness.viewerConnected.wait()
    #expect(harness.hostMetrics.snapshot().labels["connection"] == "connected")
    #expect(harness.viewerMetrics.snapshot().labels["connection"] == "connected")
    // Connection states are reported in order and never skip straight to connected.
    #expect(harness.hostConnectionStates.first == "connecting")
    #expect(!harness.hostConnectionStates.contains("failed"))

    harness.close()
    await harness.awaitClosed()
    #expect(harness.receiver.closed && harness.sender.closed)
    // Teardown released both ends: the channels refuse traffic and the native
    // connections report closed rather than lingering in connected.
    #expect(!harness.sender.controlChannel.isAvailable && !harness.receiver.controlChannel.isAvailable)
    #expect(harness.sender.connection.connectionState == .closed)
    #expect(harness.receiver.connection.connectionState == .closed)
    #expect(!harness.sender.stopRtcEventLog() && !harness.receiver.stopRtcEventLog())
  }

  @Test func theNegotiatedControlChannelCarriesMessagesInOrderInBothDirections() async throws {
    let harness = try Harness()
    defer { harness.close() }
    try await harness.negotiate()
    await harness.hostControlOpened.wait()
    await harness.viewerControlOpened.wait()
    #expect(harness.sender.controlChannel.isAvailable && harness.receiver.controlChannel.isAvailable)
    let leases = (0..<4).map { _ in UUID() }
    for lease in leases { #expect(harness.sender.controlChannel.send(.release(lease: lease))) }
    await harness.viewerControlDelivered.wait(for: leases.count)
    #expect(harness.viewerReceived == leases.map { .release(lease: $0) })
    // The reverse direction rides the same negotiated stream id.
    let request = UUID()
    #expect(harness.receiver.controlChannel.send(.request(id: request)))
    await harness.hostControlDelivered.wait()
    #expect(harness.hostReceived == [.request(id: request)])
    // The clipboard protocol has its own stream, unaffected by control traffic.
    #expect(harness.sender.clipboardChannel.isAvailable)
    #expect(harness.sender.clipboardChannel.send(.read(id: UUID())))

    harness.sender.controlChannel.close()
    #expect(harness.hostControlAvailability == [true, false])
    #expect(!harness.sender.controlChannel.send(.request(id: UUID())))
    // Closing is idempotent and does not republish the availability change.
    harness.sender.controlChannel.close()
    #expect(harness.hostControlAvailability == [true, false])
    harness.close()
    await harness.awaitClosed()
  }

  @Test func negotiationRefusesUnsupportedDescriptionsAndAnythingAfterClose() async throws {
    let source = try Harness()
    defer { source.close() }
    let offer = try await source.receiver.makeDescription(offer: true)
    #expect(offer.sdp.contains("a=fingerprint:sha-256 "))
    let peer = try ScreenSharingSender(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: ScreenSharingMetrics())
    defer { peer.close() }
    for rejected in [
      ScreenSharingDescription(version: 2, kind: "offer", sdp: offer.sdp),
      ScreenSharingDescription(kind: "pranswer", sdp: offer.sdp),
      ScreenSharingDescription(
        kind: "offer", sdp: offer.sdp.replacingOccurrences(of: "a=fingerprint:sha-256 ", with: "a=fingerprint:sha-1 ")),
      ScreenSharingDescription(kind: "offer", sdp: offer.sdp + String(repeating: "\n", count: 256 * 1024)),
    ] {
      await #expect(throws: ScreenSharingError.self) { try await peer.accept(rejected) }
    }
    try await peer.accept(offer)
    #expect(try await peer.makeDescription(offer: false).kind == "answer")
    // The negotiating guard is released on return, so re-answering the same
    // offer works — and this time gathering is already complete, which resolves
    // the wait immediately instead of through the delegate's completion event.
    try await peer.accept(offer)
    #expect(peer.connection.iceGatheringState == .complete)
    #expect(try await peer.makeDescription(offer: false).kind == "answer")

    peer.close()
    await #expect(throws: (any Error).self) { try await peer.makeDescription(offer: false) }
    await #expect(throws: (any Error).self) { try await peer.accept(offer) }
    #expect(await peer.statistics().isEmpty)
  }

  @Test func theEventLogIsStartedAndStoppedOnceAndNeverAfterClose() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = try ScreenSharingReceiver(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: ScreenSharingMetrics())
    defer { peer.close() }
    #expect(peer.startRtcEventLog(path: directory.appendingPathComponent("rtc.log").path, maxSizeBytes: 1 << 20))
    #expect(peer.stopRtcEventLog())
    peer.close()
    // A closed peer never starts a log and never credits a stop it did not make.
    #expect(!peer.startRtcEventLog(path: directory.appendingPathComponent("late.log").path, maxSizeBytes: 1 << 20))
    #expect(!peer.stopRtcEventLog())
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late.log").path))
  }

  @Test func stagingBuildsAUnifiedPlanConnectionWithTheThreeNegotiatedChannels() throws {
    let metrics = ScreenSharingMetrics()
    let staged = try ScreenSharingPeerStaging(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: metrics,
      options: ScreenSharingPeerOptions(), connectivity: nil)
    defer { staged.connection.close() }
    let configuration = staged.connection.configuration
    #expect(configuration.sdpSemantics == .unifiedPlan)
    #expect(configuration.bundlePolicy == .maxBundle && configuration.rtcpMuxPolicy == .require)
    // Direct LAN is the default: no relay credentials are embedded anywhere.
    #expect(configuration.iceServers.isEmpty && configuration.iceTransportPolicy == .all)
    #expect(!staged.controlChannel.isAvailable && !staged.clipboardChannel.isAvailable)
    #expect(!staged.videoRefresh.isAvailable)
    // Trials are pinned before any RTC object exists, and the pin is published.
    #expect(metrics.snapshot().labels["fieldTrialProvenance"] != nil)

    let relayed = try ScreenSharingPeerStaging(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: ScreenSharingMetrics(),
      options: ScreenSharingPeerOptions(),
      connectivity: try ScreenSharingICEConfiguration(
        servers: [try ScreenSharingICEServer(urls: ["turn:example.test"], username: "user", credential: "secret")],
        relayOnly: true))
    defer { relayed.connection.close() }
    #expect(relayed.connection.configuration.iceTransportPolicy == .relay)
    #expect(relayed.connection.configuration.iceServers.map(\.urlStrings) == [["turn:example.test"]])
  }
}
