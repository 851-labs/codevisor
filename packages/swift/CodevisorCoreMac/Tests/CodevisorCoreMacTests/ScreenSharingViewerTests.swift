import AppKit
import CodevisorCore
import CodevisorScreenSharing
import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerTests {
  @Test(arguments: [true, false])
  func openingRequestsControlAfterVideoAndChannelAreReady(channelFirst: Bool) async {
    let transport = SharingTransport()
    let clock = TestClock()
    let peer = SharingPeer()
    peer.deliversVideo = false
    peer.channelAvailableOnAccept = channelFirst
    let model = makeModel(transport, clock: clock) { peer }
    #expect(model.interactionMode == .control)
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    #expect(model.phase == .connecting)
    #expect(model.interactionMode == .control)
    #expect(peer.controlMessages.isEmpty)
    peer.onReady?()
    #expect(model.phase == .viewing)
    if !channelFirst {
      #expect(peer.controlMessages.isEmpty)
      peer.control.setAvailable(true)
    }
    #expect(peer.controlMessages.count == 1)
    guard case .request(let request)? = peer.controlMessages.first else {
      Issue.record("Missing automatic control request"); await model.close(); return
    }
    let lease = UUID()
    peer.control.receive(.grant(request: request, lease: lease))
    #expect(model.control?.state == .controlling)
    peer.control.release()
    #expect(model.interactionMode == .view)
    peer.onReady?()
    model.setFitToWindow(false)
    peer.control.setAvailable(true)
    #expect(peer.control.state == .viewing)
    #expect(peer.controlMessages == [.request(id: request), .release(lease: lease)])
    await model.close()
    #expect(clock.pendingCount == 0)
  }

  @Test(arguments: [ScreenSharingViewerModel.InteractionMode.view, .control])
  func connectingHonorsTheLatestModeAndSizeChoice(mode: ScreenSharingViewerModel.InteractionMode) async {
    let transport = SharingTransport(blockFirstStart: true)
    let clock = TestClock()
    let peer = SharingPeer()
    let model = makeModel(transport, clock: clock) { peer }
    model.setInteractionMode(.view)
    #expect(model.interactionMode == .view && model.control == nil)
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await transport.started.wait()
    #expect(model.phase == .connecting)
    model.setInteractionMode(.control)
    model.setInteractionMode(mode)
    model.setFitToWindow(false)
    #expect(model.interactionMode == mode)
    #expect(peer.controlMessages.isEmpty)
    transport.releaseFirstStart.signal()
    await clock.waitForSleep(.seconds(8))
    #expect(model.phase == .viewing)
    #expect(model.interactionMode == mode)
    #expect(peer.control.state == (mode == .control ? .requesting : .viewing))
    #expect(peer.controlMessages.count == (mode == .control ? 1 : 0))
    #expect(!peer.fitToWindow)
    await model.close()
    #expect(clock.pendingCount == 0)
  }

  @Test func choosingViewCancelsControlWaitingForTheChannel() async {
    let transport = SharingTransport()
    let clock = TestClock()
    let peer = SharingPeer()
    peer.channelAvailableOnAccept = false
    let model = makeModel(transport, clock: clock) { peer }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    #expect(model.phase == .viewing && model.interactionMode == .control)
    #expect(peer.controlMessages.isEmpty)
    model.setInteractionMode(.view)
    peer.control.setAvailable(true)
    #expect(model.interactionMode == .view)
    #expect(peer.controlMessages.isEmpty)
    model.setInteractionMode(.control)
    #expect(peer.control.state == .requesting)
    #expect(peer.controlMessages.count == 1)
    await model.close()
    #expect(clock.pendingCount == 0)
  }

  @Test(arguments: [true, false])
  func deniedOrRevokedControlReturnsTheModeToView(grantFirst: Bool) async throws {
    let transport = SharingTransport()
    let clock = TestClock()
    let peer = SharingPeer()
    let model = makeModel(transport, clock: clock) { peer }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    guard case .request(let request)? = peer.controlMessages.first else {
      Issue.record("Missing control request"); await model.close(); return
    }
    if grantFirst {
      let lease = UUID()
      peer.control.receive(.grant(request: request, lease: lease))
      #expect(model.interactionMode == .control && peer.control.state == .controlling)
      peer.control.receive(.revoked(lease: lease, reason: "Host ended control"))
    } else {
      peer.control.receive(.denied(request: request, reason: "Host denied control"))
    }
    #expect(model.interactionMode == .view && peer.control.state == .viewing)
    let sent = peer.controlMessages
    model.setFitToWindow(false)
    peer.onReady?()
    #expect(model.interactionMode == .view && peer.controlMessages == sent)
    await model.close()
    #expect(clock.pendingCount == 0)
  }

  @Test(arguments: [ScreenSharingViewerModel.InteractionMode.view, .control])
  func networkRecoveryUsesFreshMediaAndTheSameSessionAndPreservesMode(
    mode: ScreenSharingViewerModel.InteractionMode
  )
    async throws
  {
    let transport = SharingTransport()
    let clock = TestClock()
    var peers: [SharingPeer] = []
    let model = makeModel(transport, clock: clock) {
      let peer = SharingPeer(); peers.append(peer); return peer
    }
    model.setInteractionMode(mode)
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    let first = try #require(peers.first)
    let staleFrame = first.onReady
    first.onConnectionChanged?("disconnected")
    #expect(model.phase == .reconnecting && first.closed)
    #expect(model.videoView == nil)
    staleFrame?()
    #expect(model.phase == .reconnecting)
    await awaitObserved { model.phase == .viewing && peers.count == 2 }
    let requests = await transport.requests
    let start = try #require(requests.first { $0.operation == .start })
    let restart = try #require(requests.first { $0.operation == .restart })
    #expect(start.viewerId == restart.viewerId && start.displayId == restart.displayId)
    #expect(requests.filter { $0.operation == .start }.count == 1)
    #expect(requests.filter { $0.operation == .stop }.isEmpty)
    #expect(requests.filter { $0.operation == .capabilities && $0.viewerId == start.viewerId }.count == 2)
    #expect(first.control.state == .viewing)
    #expect(model.interactionMode == mode)
    #expect(peers[1].control.state == (mode == .control ? .requesting : .viewing))
    let count = mode == .control ? 1 : 0
    #expect(first.controlMessages.count == count && peers[1].controlMessages.count == count)
    if mode == .control { #expect(first.controlMessages != peers[1].controlMessages) }
    await model.close()
    #expect(peers.allSatisfy { $0.closed })
    #expect(clock.pendingCount == 0)
  }

  @Test func aHostStopDuringRecoveryCannotBecomeANewStart() async {
    let transport = SharingTransport(restartStatus: "stopped")
    let clock = TestClock()
    var peers: [SharingPeer] = []
    let model = makeModel(transport, clock: clock) {
      let peer = SharingPeer(); peers.append(peer); return peer
    }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    peers[0].onConnectionChanged?("disconnected")
    await awaitObserved { model.phase == .failed }
    #expect(await transport.requests.filter { $0.operation == .start }.count == 1)
    #expect(await transport.requests.filter { $0.operation == .restart }.count == 1)
    await model.close()
    #expect(peers.allSatisfy { $0.closed })
    #expect(clock.pendingCount == 0)
  }

  @Test func hidingDuringStartRejectsLateCallbacksAndStopsBeforeResuming() async throws {
    let transport = SharingTransport(blockFirstStart: true)
    let clock = TestClock()
    var peers: [SharingPeer] = []
    let model = makeModel(transport, clock: clock) {
      let peer = SharingPeer(); peers.append(peer); return peer
    }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    #expect(peers.isEmpty)
    model.connect()
    await transport.started.wait()
    let staleCallback = peers.first?.onReady
    model.setVisible(false)
    #expect(model.videoView == nil)
    #expect(model.phase == .suspended)
    staleCallback?()
    #expect(model.phase == .suspended)
    model.setVisible(true)
    transport.releaseFirstStart.signal()
    await clock.waitForSleep(.seconds(8))
    #expect(model.phase == .viewing)
    let requests = await transport.requests
    let starts = requests.filter { $0.operation == .start }
    #expect(starts.count == 2)
    #expect(starts[0].viewerId != starts[1].viewerId)
    let oldStop = try #require(requests.firstIndex { $0.operation == .stop && $0.viewerId == starts[0].viewerId })
    let newStart = try #require(requests.firstIndex { $0.operation == .start && $0.viewerId == starts[1].viewerId })
    #expect(oldStop < newStart)
    await model.close()
    #expect(clock.pendingCount == 0)
    #expect(peers.allSatisfy { $0.closed })
    #expect(await transport.stopWasCancelled == false)
  }

  @Test func aMissingPreferredDisplayNeverSelectsAnotherDisplay() async {
    let transport = SharingTransport()
    let model = makeModel(transport, clock: TestClock(), preferences: .init(preferredDisplayId: "missing")) {
      SharingPeer()
    }
    model.setVisible(true)
    await awaitObserved { model.phase == .failed }
    #expect(model.selectedDisplayId == nil)
    #expect(model.displays.count == 1)
    #expect(await transport.requests.allSatisfy { $0.operation == .capabilities })
    await model.close()
  }

  @Test func hostStopEndsViewingAtTheHeartbeatBoundary() async {
    let transport = SharingTransport(heartbeatStatus: "stopped")
    let clock = TestClock()
    let peer = SharingPeer()
    let model = makeModel(transport, clock: clock) { peer }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.setFitToWindow(false)
    model.connect()
    await clock.waitForSleep(.seconds(8))
    #expect(model.phase == .viewing)
    #expect(peer.fitToWindow == false)
    clock.advance(by: .seconds(7))
    #expect(await transport.requests.filter { $0.operation == .heartbeat }.isEmpty)
    clock.advance(by: .seconds(1))
    await awaitObserved { model.phase == .failed }
    await model.close()
    #expect(peer.closed)
    #expect(model.videoView == nil)
    #expect(clock.pendingCount == 0)
  }

  @Test func missingVideoTimesOutAndLateFirstFrameCannotReviveTheConnection() async {
    let transport = SharingTransport()
    let clock = TestClock()
    let peer = SharingPeer()
    peer.deliversVideo = false
    let model = makeModel(transport, clock: clock) { peer }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    let lateFrame = peer.onReady
    for _ in 0..<2 {
      clock.advance(by: .seconds(8))
      await clock.waitForSleep(.seconds(8))
      #expect(model.phase == .connecting)
    }
    clock.advance(by: .seconds(7))
    #expect(model.phase == .connecting)
    clock.advance(by: .seconds(1))
    await awaitObserved { model.phase == .failed }
    lateFrame?()
    #expect(model.phase == .failed)
    #expect(model.message?.contains("No video arrived") == true)
    await model.close()
    #expect(peer.closed)
    #expect(clock.pendingCount == 0)
  }

  @Test func decoderFailureEndsViewingAtTheNextHeartbeat() async {
    let transport = SharingTransport()
    let clock = TestClock()
    let peer = SharingPeer()
    let model = makeModel(transport, clock: clock) { peer }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    peer.failure = "Fixture hardware decoder failed"
    clock.advance(by: .seconds(8))
    await awaitObserved { model.phase == .failed }
    #expect(model.message == peer.failure)
    await model.close()
    #expect(peer.closed)
  }

  @Test func incomingPreferencesUpdateTheLiveSurfaceWithoutEchoOrReconnect() async {
    let transport = SharingTransport()
    let clock = TestClock()
    let peer = SharingPeer()
    let model = makeModel(transport, clock: clock) { peer }
    model.setVisible(true)
    await awaitObserved { model.phase == .ready }
    model.connect()
    await clock.waitForSleep(.seconds(8))
    var echoed = false
    model.onPreferencesChanged = { _ in echoed = true }
    var preferences = model.preferences
    preferences.fitToWindow = false
    model.applyPreferences(preferences)
    model.applyPreferences(preferences)
    #expect(model.videoView === peer.view)
    #expect(model.phase == .viewing)
    #expect(!peer.fitToWindow)
    #expect(!peer.closed)
    #expect(!echoed)
    #expect(await transport.requests.filter { $0.operation == .start }.count == 1)

    preferences.preferredDisplayId = "missing"
    model.applyPreferences(preferences)
    await awaitObserved { model.phase == .failed }
    #expect(model.videoView == nil)
    #expect(peer.closed)
    #expect(await transport.requests.filter { $0.operation == .start }.count == 1)
    #expect(!echoed)
    await model.close()
  }

  private func makeModel(
    _ transport: SharingTransport, clock: TestClock,
    preferences: ScreenSharingPanePreferences = .init(), makePeer: @escaping () -> SharingPeer
  ) -> ScreenSharingViewerModel {
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    return ScreenSharingViewerModel(
      client: client, workspaceId: UUID(), paneId: UUID(), preferences: preferences,
      makePeer: { _ in makePeer() }, sleep: { try await clock.sleep(for: $0) })
  }
}

@MainActor
private final class SharingPeer: ScreenSharingViewingPeer {
  let view = NSView()
  var controlMessages: [ScreenSharingControlMessage] = []
  lazy var control = ScreenSharingViewerControl(
    now: { 0 },
    send: { [weak self] in
      self?.controlMessages.append($0); return true
    })
  var clipboard: ScreenSharingViewerClipboard? { nil }
  let diagnostics = ScreenSharingViewerDiagnostics()
  var failure: String?
  var deliversVideo = true
  var channelAvailableOnAccept = true
  var onReady: (() -> Void)?
  var onConnectionChanged: ((String) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var closed = false
  var fitToWindow = true
  func offer() async throws -> String { "fixture offer" }
  func accept(_ answer: String) async throws {
    control.setAvailable(channelAvailableOnAccept)
    if deliversVideo { onReady?() }
  }
  func fit(_ enabled: Bool) { fitToWindow = enabled }
  func close() { closed = true; control.release(); onReady = nil; onConnectionChanged = nil }
}

private actor SharingTransport: ServerRequestTransport {
  nonisolated let started = TestSignal()
  nonisolated let releaseFirstStart = TestSignal()
  private let blockFirstStart: Bool
  private let heartbeatStatus: String
  private let restartStatus: String
  private(set) var requests: [ServerScreenSharingRequest] = []
  private(set) var stopWasCancelled = false
  init(blockFirstStart: Bool = false, heartbeatStatus: String = "viewing", restartStatus: String = "connecting") {
    self.blockFirstStart = blockFirstStart; self.heartbeatStatus = heartbeatStatus
    self.restartStatus = restartStatus
  }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let payload = try JSONDecoder().decode(ServerScreenSharingRequest.self, from: request.httpBody ?? Data())
    requests.append(payload)
    let reply: ServerScreenSharingReply
    switch payload.operation {
    case .capabilities:
      reply = .init(status: "available", displays: [.init(id: "display", name: "Display", width: 1920, height: 1080)])
    case .start, .restart:
      let first = requests.filter { $0.operation == .start }.count == 1
      started.signal()
      if first, blockFirstStart { await releaseFirstStart.wait() }
      reply = .init(status: payload.operation == .restart ? restartStatus : "connecting", answer: "fixture answer")
    case .heartbeat: reply = .init(status: heartbeatStatus)
    case .stop:
      stopWasCancelled = stopWasCancelled || Task.isCancelled
      reply = .init(status: "stopped")
    }
    return (
      try JSONEncoder().encode(reply),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}
