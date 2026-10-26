import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC
@preconcurrency import WebRTC

@MainActor
struct ScreenSharingPeerLoopbackTests {
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

    init(width: Int = 128, height: Int = 64) async throws {
      let configuration = try ScreenSharingVideoConfiguration(width: width, height: height)
      sender = try await ScreenSharingSender(configuration: configuration, metrics: hostMetrics)
      receiver = try await ScreenSharingReceiver(configuration: configuration, metrics: viewerMetrics)
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
    let harness = try await Harness()
    defer { harness.close() }
    try await harness.negotiate()
    let tracks = await harness.receiver.transport.inspect { $0?.receivers.compactMap { $0.track?.kind } ?? [] }
    #expect(tracks == ["video"])
    #expect(await harness.sender.transport.inspect { $0?.transceivers.contains { $0.direction == .sendOnly } == true })
    await harness.hostConnected.wait()
    await harness.viewerConnected.wait()
    #expect(harness.hostMetrics.snapshot().labels["connection"] == "connected")
    #expect(harness.viewerMetrics.snapshot().labels["connection"] == "connected")
    #expect(harness.hostConnectionStates.first == "connecting")
    #expect(!harness.hostConnectionStates.contains("failed"))

    harness.close()
    await harness.awaitClosed()
    #expect(harness.receiver.closed && harness.sender.closed)
    #expect(!harness.sender.controlChannel.isAvailable && !harness.receiver.controlChannel.isAvailable)
    #expect(await harness.sender.transport.inspect { $0 == nil })
    #expect(await harness.receiver.transport.inspect { $0 == nil })
  }

  @Test func theNegotiatedControlChannelCarriesMessagesInOrderInBothDirections() async throws {
    let harness = try await Harness()
    defer { harness.close() }
    try await harness.negotiate()
    await harness.hostControlOpened.wait()
    await harness.viewerControlOpened.wait()
    #expect(harness.sender.controlChannel.isAvailable && harness.receiver.controlChannel.isAvailable)
    let leases = (0..<4).map { _ in UUID() }
    for lease in leases { #expect(harness.sender.controlChannel.send(.release(lease: lease))) }
    await harness.viewerControlDelivered.wait(for: leases.count)
    #expect(harness.viewerReceived == leases.map { .release(lease: $0) })
    let request = UUID()
    #expect(harness.receiver.controlChannel.send(.request(id: request)))
    await harness.hostControlDelivered.wait()
    #expect(harness.hostReceived == [.request(id: request)])
    #expect(harness.sender.clipboardChannel.isAvailable)
    #expect(harness.sender.clipboardChannel.send(.read(id: UUID())))

    harness.sender.controlChannel.close()
    #expect(harness.hostControlAvailability == [true, false])
    #expect(!harness.sender.controlChannel.send(.request(id: UUID())))
    harness.sender.controlChannel.close()
    #expect(harness.hostControlAvailability == [true, false])
    harness.close()
    await harness.awaitClosed()
  }

  @Test func aViewerThatDrawsThePointerSubscribesAndReceivesIt() async throws {
    let harness = try await Harness()
    defer { harness.close() }
    let subscribed = TestSignal()
    let updated = TestSignal()
    var updates: [ScreenSharingCursorUpdate] = []
    harness.sender.cursorChannel.onMessage = { if case .subscribe = $0 { subscribed.signal() } }
    harness.receiver.onCursorChanged = {
      updates.append($0)
      updated.signal()
    }
    try await harness.negotiate()
    await subscribed.wait()
    #expect(harness.receiver.videoShowsPointer, "the video keeps the pointer until the host sends one")
    let png = try #require(
      ScreenSharingCursorImage.png(pixelWidth: 2, pixelHeight: 2) { context in
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
      })
    let image = ScreenSharingCursorImage(png: png, hotspotX: 1, hotspotY: 1, width: 0.01, height: 0.02)
    #expect(harness.sender.cursorChannel.send(.shape(image)))
    #expect(harness.sender.cursorChannel.send(.position(ScreenSharingPointer(x: 0.5, y: 0.25))))
    await updated.wait(for: 2)
    let shape = try #require(image.shape())
    #expect(
      updates == [
        .sizedShape(shape, width: 0.01, height: 0.02), .normalizedPosition(ScreenSharingPointer(x: 0.5, y: 0.25)),
      ])
    #expect(!harness.receiver.videoShowsPointer)
    var replayed: [ScreenSharingCursorUpdate] = []
    harness.receiver.onCursorChanged = { replayed.append($0) }
    #expect(replayed == updates)
  }

  @Test func aViewerPlayingSoundSubscribesReceivesPacketsAndUnsubscribesOnMute() async throws {
    let harness = try await Harness()
    defer { harness.close() }
    let hostHeard = TestSignal()
    var hostReceived: [ScreenSharingAudioMessage] = []
    harness.sender.audioChannel.onMessage = {
      hostReceived.append($0)
      hostHeard.signal()
    }
    harness.receiver.setAudioEnabled(true)
    try await harness.negotiate()
    await hostHeard.wait()
    #expect(hostReceived == [.subscribe])
    let packet = ScreenSharingAudioPacket(sequence: 0, timestampNs: 1, frames: 960, payload: Data([1, 2, 3]))
    #expect(harness.sender.audioChannel.send(.packet(packet)))
    harness.receiver.setAudioEnabled(false)
    await hostHeard.wait(for: 2)
    #expect(hostReceived == [.subscribe, .unsubscribe])
  }

  @Test func theViewerSendsItsPaneSizeOnceTheHostIsReady() async throws {
    let harness = try await Harness()
    defer { harness.close() }
    let opened = TestSignal()
    let hostHeard = TestSignal()
    var hostReceived: [ScreenSharingDisplayMessage] = []
    var support: [Bool] = []
    harness.sender.displayChannel.onAvailabilityChanged = { if $0 { opened.signal() } }
    harness.sender.displayChannel.onMessage = {
      hostReceived.append($0)
      hostHeard.signal()
    }
    harness.receiver.onResizeSupportChanged = { support.append($0) }
    harness.receiver.requestDesktopSize(width: 1000, height: 700)
    harness.receiver.requestDesktopSize(width: 1280, height: 800)
    try await harness.negotiate()
    await opened.wait()
    #expect(harness.sender.displayChannel.send(.ready))
    await hostHeard.wait()
    #expect(hostReceived == [.resize(width: 1280, height: 800)])
    #expect(support == [true])
    harness.receiver.requestDesktopSize(width: 1280, height: 800)
    harness.receiver.resetDesktopSize()
    await hostHeard.wait(for: 2)
    #expect(hostReceived == [.resize(width: 1280, height: 800), .restore], "the same size isn't sent twice")
  }

  @Test func negotiationRefusesUnsupportedDescriptionsAndAnythingAfterClose() async throws {
    let source = try await Harness()
    defer { source.close() }
    let offer = try await source.receiver.makeDescription(offer: true)
    #expect(offer.sdp.contains("a=fingerprint:sha-256 "))
    let peer = try await ScreenSharingSender(
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
    try await peer.accept(offer)
    #expect(await peer.transport.inspect { $0?.iceGatheringState == .complete })
    #expect(try await peer.makeDescription(offer: false).kind == "answer")

    peer.close()
    await #expect(throws: (any Error).self) { try await peer.makeDescription(offer: false) }
    await #expect(throws: (any Error).self) { try await peer.accept(offer) }
    #expect(await peer.statistics().isEmpty)
  }

  struct ConnectionShape: Sendable, Equatable {
    var unifiedPlan: Bool
    var maxBundle: Bool
    var rtcpMuxRequired: Bool
    var relayOnly: Bool
    var iceServerURLs: [[String]]
    var builtOnMain: Bool
  }

  private func stage(
    connectivity: ScreenSharingICEConfiguration?, metrics: ScreenSharingMetrics = .init()
  )
    async throws -> (ScreenSharingPeerStaging, ConnectionShape)
  {
    try await ScreenSharingPeerStaging.make(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: metrics,
      options: ScreenSharingPeerOptions(), connectivity: connectivity
    ) { _, connection, _, _ in
      let configuration = connection.configuration
      return ConnectionShape(
        unifiedPlan: configuration.sdpSemantics == .unifiedPlan, maxBundle: configuration.bundlePolicy == .maxBundle,
        rtcpMuxRequired: configuration.rtcpMuxPolicy == .require,
        relayOnly: configuration.iceTransportPolicy == .relay,
        iceServerURLs: configuration.iceServers.map(\.urlStrings), builtOnMain: Thread.isMainThread)
    }
  }

  private func release(_ staged: ScreenSharingPeerStaging) async {
    let channels =
      [
        staged.controlChannel, staged.clipboardChannel, staged.cursorChannel, staged.audioChannel,
        staged.displayChannel, staged.videoFormatChannel, staged.videoRefresh,
      ] as [any ScreenSharingQueuedChannel]
    staged.controlChannel.close(); staged.clipboardChannel.close(); staged.cursorChannel.close()
    staged.audioChannel.close(); staged.displayChannel.close(); staged.videoFormatChannel.close()
    staged.videoRefresh.close()
    staged.transport.close(after: channels)
    await staged.transport.awaitTeardown()
  }

  @Test func stagingBuildsAUnifiedPlanConnectionWithTheNegotiatedChannelsOffTheMainThread() async throws {
    let metrics = ScreenSharingMetrics()
    let (staged, shape) = try await stage(connectivity: nil, metrics: metrics)
    #expect(!shape.builtOnMain, "the factory, connection and channels are built on the transport's queue")
    #expect(shape.unifiedPlan && shape.maxBundle && shape.rtcpMuxRequired)
    #expect(shape.iceServerURLs.isEmpty && !shape.relayOnly)
    #expect(!staged.controlChannel.isAvailable && !staged.clipboardChannel.isAvailable)
    #expect(!staged.cursorChannel.isAvailable && !staged.audioChannel.isAvailable)
    #expect(!staged.videoRefresh.isAvailable)
    #expect(metrics.snapshot().labels["fieldTrialProvenance"] != nil)
    await release(staged)

    let (relayed, relayedShape) = try await stage(
      connectivity: try ScreenSharingICEConfiguration(
        servers: [try ScreenSharingICEServer(urls: ["turn:example.test"], username: "user", credential: "secret")],
        relayOnly: true))
    #expect(relayedShape.relayOnly)
    #expect(relayedShape.iceServerURLs == [["turn:example.test"]])
    await release(relayed)
  }

  @Test func closeReturnsWhileWebRTCIsBusyAndTheTeardownFollowsInOrder() async throws {
    let peer = try await ScreenSharingSender(
      configuration: try ScreenSharingVideoConfiguration(width: 64, height: 64), metrics: ScreenSharingMetrics())
    let held = TestSignal()
    let hold = DispatchSemaphore(value: 0)
    peer.transport.queue.async {
      held.signal()
      hold.wait()
    }
    await held.wait()
    peer.close()
    #expect(peer.closed && !peer.controlChannel.isAvailable)
    #expect(await peer.statistics().isEmpty, "a closed peer asks WebRTC for nothing")
    hold.signal()
    #expect(await peer.awaitClosed() != nil)
    #expect(await peer.transport.inspect { $0 == nil }, "the connection was closed and released on its queue")
  }
}
