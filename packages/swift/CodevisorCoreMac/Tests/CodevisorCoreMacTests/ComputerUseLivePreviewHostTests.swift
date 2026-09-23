import CoreGraphics
import Foundation
import ScreenSharing
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
@Suite("Computer Use live preview host")
struct ComputerUseLivePreviewHostTests {
  static let session = "0f8fad5b-d9cb-469f-a165-70867728950e"
  static let target = "computer-use:\(session)"
  static let offer = "v=0\r\na=fingerprint:sha-256 fixture\r\n"

  @Test("Parses only computer-use targets naming a session")
  func targets() {
    #expect(ComputerUseStreamTarget.sessionID(from: Self.target) == Self.session)
    #expect(ComputerUseStreamTarget.sessionID(from: Self.target.uppercased()) == nil)
    #expect(ComputerUseStreamTarget.sessionID(from: "computer-use:\(Self.session.uppercased())") == Self.session)
    #expect(ComputerUseStreamTarget.sessionID(from: "computer-use:nope") == nil)
    #expect(ComputerUseStreamTarget.sessionID(from: Self.session) == nil)
    #expect(ComputerUseStreamTarget.sessionID(from: nil) == nil)
  }

  @Test("Advertises the controlled app only while the agent is active")
  func capabilities() async {
    let world = World()
    let host = world.host()
    #expect(await host.handle(world.request(.capabilities)).status == "unavailable")

    world.activityState = .active
    let reply = await host.handle(world.request(.capabilities))
    #expect(reply.status == "available")
    #expect(reply.displays.map(\.id) == [Self.target])
    #expect(reply.displays.first?.name == "TextEdit")
    #expect(reply.displays.first?.width == 960)
    #expect(reply.connectivity != nil)

    world.activityState = .idle
    #expect(await host.handle(world.request(.capabilities)).status == "unavailable")
    world.activityState = .active
    world.access = false
    #expect(await host.handle(world.request(.capabilities)).status == "permission-required")
  }

  @Test("Answers, feeds frames, reports connection state, and releases on stop")
  func lifecycle() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()

    let started = await host.handle(world.request(.start, offer: Self.offer))
    #expect(started.status == "connecting")
    #expect(started.answer == "answer")
    let peer = try #require(world.peers.first)
    #expect(world.attached.count == 1)
    #expect(world.attached.first?.sessionID == "BRIDGE-ID")
    #expect(world.attached.first?.sink === peer.sink)
    #expect(await host.handle(world.request(.heartbeat)).status == "connecting")

    peer.onConnectionChanged?("connected")
    #expect(await host.handle(world.request(.heartbeat)).status == "viewing")
    peer.onConnectionChanged?("disconnected")
    #expect(await host.handle(world.request(.heartbeat)).status == "reconnecting")

    #expect(await host.handle(world.request(.stop)).status == "stopped")
    #expect(peer.closed)
    #expect(world.detached == world.attached.map(\.token))
    #expect(host.sessionCount == 0)
    #expect(await host.handle(world.request(.heartbeat)).status == "stopped")
  }

  @Test("Restart replaces the viewer's media peer")
  func restart() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()
    _ = await host.handle(world.request(.start, offer: Self.offer))
    #expect(await host.handle(world.request(.restart, offer: Self.offer)).status == "connecting")
    #expect(world.peers.count == 2)
    #expect(world.peers[0].closed)
    #expect(!world.peers[1].closed)
    #expect(host.sessionCount == 1)
  }

  @Test("Ends viewers when the agent stops controlling the app")
  func activityStops() async {
    let world = World()
    world.activityState = .active
    let host = world.host()
    _ = await host.handle(world.request(.start, offer: Self.offer))
    world.activityState = .stopped
    host.activityChanged()
    #expect(world.peers.first?.closed == true)
    #expect(host.sessionCount == 0)
  }

  @Test("A viewer that stops heartbeating is expired")
  func expiry() async {
    let world = World()
    world.activityState = .active
    let host = world.host()
    _ = await host.handle(world.request(.start, offer: Self.offer))
    world.clock += ComputerUseLivePreviewHost.lifetime + 1
    #expect(await host.handle(world.request(.heartbeat)).status == "stopped")
    #expect(world.peers.first?.closed == true)
  }

  @Test("Several viewers may watch, up to a bound")
  func viewerBound() async {
    let world = World()
    world.activityState = .active
    let host = world.host()
    for _ in 0..<ComputerUseLivePreviewHost.maximumSessions {
      let reply = await host.handle(world.request(.start, offer: Self.offer, viewer: UUID()))
      #expect(reply.status == "connecting")
    }
    let extra = await host.handle(world.request(.start, offer: Self.offer, viewer: UUID()))
    #expect(extra.status == "busy")
    #expect(host.sessionCount == ComputerUseLivePreviewHost.maximumSessions)
    host.shutdown()
    #expect(!world.peers.contains { !$0.closed })
    #expect(await host.handle(world.request(.capabilities)).status == "stopped")
  }

  @Test("Rejects invalid offers and targets without creating media")
  func validation() async {
    let world = World()
    world.activityState = .active
    let host = world.host()
    #expect(await host.handle(world.request(.start, offer: "v=0")).status == "failed")
    var wrong = world.request(.capabilities)
    wrong.displayId = "computer-use:nope"
    #expect(await host.handle(wrong).status == "failed")
    #expect(world.peers.isEmpty)
  }
}

@MainActor
private final class World {
  var access = true
  var activityState: ComputerUseLivePreview.State?
  var clock: TimeInterval = 100
  var peers: [FakePeer] = []
  var attached: [(sessionID: String, sink: any ComputerUseFrameSink, token: UUID)] = []
  var detached: [UUID] = []
  let workspace = UUID()
  let pane = UUID()
  let viewer = UUID()

  func request(
    _ operation: ServerScreenSharingRequest.Operation,
    offer: String? = nil,
    viewer: UUID? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: workspace, paneId: pane, viewerId: viewer ?? self.viewer,
      displayId: ComputerUseLivePreviewHostTests.target, offer: offer)
  }

  func host() -> ComputerUseLivePreviewHost {
    ComputerUseLivePreviewHost(
      dependencies: .init(
        captureAccess: { [unowned self] in access },
        activity: { [unowned self] id in
          guard let state = activityState, id == ComputerUseLivePreviewHostTests.session else { return nil }
          return .init(
            sessionID: id, bridgeSessionID: "BRIDGE-ID", appName: "TextEdit", pid: 42, windowID: 7,
            windowFrame: CGRect(x: 0, y: 0, width: 600, height: 400), colorIndex: 0, cursor: nil,
            state: state)
        },
        streamSize: { _ in CGSize(width: 960, height: 640) },
        attach: { [unowned self] id, sink in
          let token = UUID()
          attached.append((id, sink, token))
          return token
        },
        detach: { [unowned self] _, token in detached.append(token) },
        makePeer: { [unowned self] _, _ in
          let peer = FakePeer()
          peers.append(peer)
          return peer
        },
        makeConnectivity: { _ in .init(servers: [], relayOnly: false, expiresAt: 0) },
        now: { [unowned self] in clock }
      ))
  }
}

@MainActor
private final class FakePeer: ComputerUseStreamPeer {
  var onConnectionChanged: ((String) -> Void)?
  let sink: any ComputerUseFrameSink = RecordingSink()
  var closed = false

  func answer(offer: String) async throws -> String { "answer" }
  func close() { closed = true }
}
