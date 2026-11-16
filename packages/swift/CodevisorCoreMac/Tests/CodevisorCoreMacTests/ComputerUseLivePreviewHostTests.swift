import CoreGraphics
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
@Suite("Computer Use live preview host")
struct ComputerUseLivePreviewHostTests {
  static let session = "0f8fad5b-d9cb-469f-a165-70867728950e"
  static let target = "computer-use:\(session)"
  static let viewerEndpoint = String(repeating: "b", count: 64)
  static let grant = ServerScreenSharingMediaGrant(
    endpointId: String(repeating: "a", count: 64), relayUrl: nil, directAddrs: ["10.0.0.2:4433"], token: "token")

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
    let world = ComputerUseLivePreviewHostWorld()
    let host = world.host()
    let notControlling = await host.handle(world.request(.capabilities))
    #expect(notControlling.status == "unavailable")
    #expect(Self.viewerSeesActivity(notControlling) == false)

    world.activityState = .active
    let reply = await host.handle(world.request(.capabilities))
    #expect(reply.status == "available")
    #expect(Self.viewerSeesActivity(reply) == true)
    #expect(reply.displays.map(\.id) == [Self.target])
    #expect(reply.displays.first?.name == "TextEdit")
    #expect(reply.displays.first?.width == 960)

    world.activityState = .idle
    let idle = await host.handle(world.request(.capabilities))
    #expect(idle.status == "unavailable")
    #expect(Self.viewerSeesActivity(idle) == false)
    world.activityState = .active
    world.access = false
    let denied = await host.handle(world.request(.capabilities))
    #expect(denied.status == "permission-required")
    #expect(Self.viewerSeesActivity(denied) == nil)
  }

  private static func viewerSeesActivity(_ reply: ServerScreenSharingReply) -> Bool? {
    ScreenSharingTargetActivity.isActive(reply, target: target)
  }

  @Test("Grants media, feeds frames, reports connection state, and releases on stop")
  func lifecycle() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    let host = world.host()

    let started = try await world.started(on: host)
    #expect(started.reply.status == "connecting")
    #expect(started.reply.media == Self.grant)
    let peer = try #require(world.peers.first)
    #expect(world.attached.count == 1)
    #expect(world.attached.first?.sessionID == "BRIDGE-ID")
    #expect(world.attached.first?.sink === peer.sink)
    #expect(await host.handle(world.following(started, .heartbeat)).status == "connecting")

    peer.onConnectionChanged?("connected")
    #expect(await host.handle(world.following(started, .heartbeat)).status == "viewing")
    peer.onConnectionChanged?("disconnected")
    #expect(await host.handle(world.following(started, .heartbeat)).status == "reconnecting")

    #expect(await host.handle(world.following(started, .stop)).status == "stopped")
    #expect(peer.closed)
    #expect(world.detached == world.attached.map(\.token))
    #expect(host.sessionCount == 0)
    #expect(await host.handle(world.following(started, .heartbeat)).status == "stopped")
  }

  @Test("Lists engine v2 when this Mac has a media endpoint, and starts a v2 viewer with a media grant")
  func engineV2() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    let host = world.host()
    #expect(await host.handle(world.request(.capabilities)).engines == nil)
    world.offersV2 = true
    #expect(await host.handle(world.request(.capabilities)).engines == ["v2"])

    let started = try await world.started(on: host)

    #expect(started.reply.status == "connecting")
    #expect(started.reply.media == Self.grant)
    #expect(world.requestedMedia == [.init(viewerEndpointId: ServerScreenSharingApp.macBook.key)])
    #expect(world.attached.first?.sink === world.peers.first?.sink)
  }

  @Test("Tells viewers why no video is coming while the window is out of sight, and clears it once shown")
  func windowNotice() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    world.windowVisibility = .appHidden
    let host = world.host()
    let started = try await world.started(on: host)
    #expect(started.reply.status == "connecting")
    #expect(started.reply.message == "TextEdit is hidden")
    world.windowVisibility = .minimized
    #expect(await host.handle(world.following(started, .heartbeat)).message == "Window is minimized")
    world.windowVisibility = .visible
    let shown = await host.handle(world.following(started, .heartbeat))
    #expect(shown.status == "connecting")
    #expect(shown.message == nil)
  }

  @Test("Ends viewers when the agent stops controlling the app")
  func activityStops() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    let host = world.host()
    _ = try await world.started(on: host)
    world.activityState = .stopped
    host.activityChanged()
    #expect(world.peers.first?.closed == true)
    #expect(host.sessionCount == 0)
  }

  @Test("A viewer that stops heartbeating is expired")
  func expiry() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    let host = world.host()
    let started = try await world.started(on: host)
    world.clock += ComputerUseLivePreviewHost.lifetime + 1
    #expect(await host.handle(world.following(started, .heartbeat)).status == "stopped")
    #expect(world.peers.first?.closed == true)
  }

  @Test("Several apps may watch, up to a bound")
  func viewerBound() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    let host = world.host()
    for number in 0..<ComputerUseLivePreviewHost.maximumSessions {
      #expect(try await world.started(as: .viewer(number), on: host).reply.status == "connecting")
    }
    let extra = try await world.started(as: .viewer(99), on: host).reply
    #expect(extra.status == "busy")
    #expect(host.sessionCount == ComputerUseLivePreviewHost.maximumSessions)
    host.shutdown()
    #expect(!world.peers.contains { !$0.closed })
    #expect(await host.handle(world.request(.capabilities)).status == "stopped")
  }

  @Test("Rejects starts without a v2 viewer address, and invalid targets, without creating media")
  func validation() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    let host = world.host()
    var noMedia = try await world.start(as: .macBook, on: host)
    noMedia.media = nil
    #expect(await host.handle(noMedia).status == "failed")
    var wrong = world.request(.capabilities)
    wrong.displayId = "computer-use:nope"
    #expect(await host.handle(wrong).status == "failed")
    #expect(world.peers.isEmpty)
  }

  @Test("Closes a peer that finishes building after shutdown")
  func shutdownWhileBuilding() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    world.peerGate = TestSignal()
    let host = world.host()
    let request = try await world.start(as: .macBook, on: host)
    let start = Task { await host.handle(request) }
    await world.peerRequested.wait()
    host.shutdown()
    world.peerGate?.signal()
    #expect(await start.value.status == "stopped")
    #expect(world.peers.count == 1 && world.peers.allSatisfy(\.closed))
    #expect(world.attached.isEmpty && host.sessionCount == 0)
  }
}
