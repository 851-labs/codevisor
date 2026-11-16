import CodevisorTestSupport
import CoreGraphics
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
@Suite("Simulator stream host: sessions, viewers and app-owned sessions")
struct SimulatorStreamHostSessionTests {
  typealias World = SimulatorStreamHostWorld

  static let shutDown = "The simulator shut down."

  @Test func capabilitiesSayWhetherTheSimulatorCanBeStreamedNow() async {
    let world = World()
    let host = world.host()

    let ready = await host.handle(world.request(.capabilities))
    #expect(ready.status == "available" && ready.engines == ["v2"])
    #expect(ready.displays.map(\.id) == [World.target])

    world.booted = []
    let starting = await host.handle(world.request(.capabilities))
    #expect(starting.status == "starting" && starting.message == "The simulator is starting.")

    world.lookupFailure = "That simulator no longer exists."
    let gone = await host.handle(world.capabilities(as: .macBook))
    #expect(gone.status == "unavailable" && gone.message == "That simulator no longer exists.")

    world.isLoaded = false
    let noXcode = await host.handle(world.capabilities(as: .macBook))
    #expect(noXcode.status == "unavailable")
    #expect(noXcode.message == "Install Xcode on this Mac to use its simulators.")
  }

  @Test func anAppIsOfferedAppSessionsAndToldWhenThereIsNothingToViewYet() async {
    let world = World()
    let host = world.host()

    let ready = await host.handle(world.capabilities(as: .macBook))
    #expect(ready.status == "available" && ready.abilities == [ServerScreenSharingReply.appSessions])
    #expect(ready.challenge?.hostKey == world.hostKey && ready.challenge?.nonce.count == 64)

    world.booted = []
    let starting = await host.handle(world.capabilities(as: .macBook))
    #expect(starting.status == "starting" && starting.reason == .nothingToView && starting.challenge == nil)
  }

  @Test func aViewerIsGrantedMediaShownTheScreenAndReleasedOnStop() async throws {
    let world = World()
    let host = world.host()

    let started = try await world.started(on: host)
    let peer = try #require(world.peers.first)
    let device = try #require(world.devices.first)
    #expect(started.reply.status == "connecting" && started.reply.media == World.grant)
    #expect(device.sinks.count == 1 && device.sinks.first === peer)
    #expect(await host.handle(world.following(started, .heartbeat)).status == "connecting")

    peer.onConnectionChanged?("connected")
    #expect(await host.handle(world.following(started, .heartbeat)).status == "viewing")
    peer.onConnectionChanged?("disconnected")
    #expect(await host.handle(world.following(started, .heartbeat)).status == "reconnecting")

    #expect(await host.handle(world.following(started, .stop)).status == "stopped")
    #expect(peer.isClosed && device.sinks.isEmpty && device.touchesReleased == 1 && device.isClosed)
    #expect(host.sessionCount == 0)
    #expect(await host.handle(world.following(started, .heartbeat)).status == "stopped")
  }

  @Test func viewersOfOneSimulatorShareItsDeviceWhichClosesWithTheLastOne() async throws {
    let world = World()
    let host = world.host()
    let first = try await world.started(as: .macBook, on: host)
    let second = try await world.started(as: .iPhone, on: host)
    let device = try #require(world.devices.first)
    #expect(world.devices.count == 1 && device.sinks.count == 2)

    _ = await host.handle(world.following(first, .stop))
    #expect(!device.isClosed && device.sinks.count == 1)

    _ = await host.handle(world.following(second, .stop))
    #expect(device.isClosed && device.sinks.isEmpty)

    _ = try await world.started(as: .macBook, on: host)
    #expect(world.devices.count == 2, "a simulator viewed again is opened afresh")
  }

  @Test func aStartThatFailsLeavesNoViewerBehind() async throws {
    let world = World()
    let host = world.host()

    world.captureFails = true
    #expect(try await world.started(on: host).reply.status == "failed")
    #expect(world.devices.count == 1 && world.devices[0].isClosed)

    world.captureFails = false
    world.screenSize = nil
    let notReady = try await world.started(on: host).reply
    #expect(notReady.status == "starting" && notReady.message == "The simulator's screen isn't ready yet.")
    #expect(world.devices.count == 2 && world.devices[1].isClosed && world.peers.isEmpty)

    world.screenSize = CGSize(width: 402, height: 874)
    var noMedia = try await world.start(as: .macBook, on: host)
    noMedia.media = nil
    #expect(await host.handle(noMedia).status == "failed")
    #expect(world.devices.count == 2 && host.sessionCount == 0)
  }

  @Test func aSignedStartIsGrantedASessionTokenThatHeartbeatsAndStopsIt() async throws {
    let world = World()
    let host = world.host()

    let start = try await world.start(as: .macBook, on: host)
    let granted = await host.handle(start)
    let token = try #require(granted.session)
    #expect(granted.status == "connecting" && granted.media == World.grant && token.count == 64)

    #expect(await host.handle(world.following(start, .heartbeat, session: token)).status == "connecting")
    #expect(await host.handle(world.following(start, .heartbeat, session: token.uppercased())).status == "connecting")
    let wrong = String(repeating: "0", count: 64)
    #expect(await host.handle(world.following(start, .heartbeat, session: wrong)).status == "stopped")
    _ = await host.handle(world.following(start, .stop, session: wrong))
    #expect(host.sessionCount == 1)

    _ = await host.handle(world.following(start, .stop, session: token))
    #expect(host.sessionCount == 0 && world.peers.allSatisfy(\.isClosed) && world.devices.allSatisfy(\.isClosed))
  }

  @Test func aStartWhoseKeyIsNotProvenCreatesNothingAndGetsAFreshChallenge() async throws {
    let world = World()
    let host = world.host()

    var unsigned = try await world.start(as: .macBook, on: host)
    unsigned.proof = .init(nonce: String(repeating: "0", count: 64), signature: String(repeating: "0", count: 128))
    var retargeted = try await world.start(as: .macBook, on: host)
    retargeted.displayId = "simulator:\(UUID().uuidString)"
    let replayed = try await world.start(as: .macBook, on: host)
    _ = await host.handle(replayed)
    _ = await host.handle(world.following(replayed, .stop, session: nil))

    for request in [unsigned, retargeted, replayed] {
      let reply = await host.handle(request)
      #expect(reply.status == "failed" && reply.reason == .proofRejected)
      #expect(reply.media == nil && reply.session == nil && reply.challenge?.nonce.count == 64)
    }
    #expect(host.sessionCount == 0 && world.devices.allSatisfy(\.isClosed))
  }

  @Test func theSameAppReplacesItsOwnSessionOnASimulatorAndKeepsOnePerSimulator() async throws {
    let world = World()
    let other = "5A1D0C11-0000-4000-8000-000000000002"
    world.booted.insert(other)
    let host = world.host()

    let first = try await world.start(as: .macBook, on: host)
    let firstToken = await host.handle(first).session
    let second = try await world.start(as: .macBook, on: host, target: "simulator:\(World.udid.lowercased())")
    let secondToken = await host.handle(second).session
    #expect(host.sessionCount == 1 && world.peers.map(\.isClosed) == [true, false])
    #expect(await host.handle(world.following(first, .heartbeat, session: firstToken)).status == "stopped")
    #expect(await host.handle(world.following(second, .heartbeat, session: secondToken)).status == "connecting")

    let elsewhere = try await world.start(as: .macBook, on: host, target: "simulator:\(other)")
    let phone = try await world.start(as: .iPhone, on: host)
    #expect(await host.handle(elsewhere).status == "connecting")
    #expect(await host.handle(phone).status == "connecting")
    #expect(host.sessionCount == 3 && world.devices.count == 3)
  }

  @Test func theSessionLimitKeepsItsReply() async throws {
    let world = World()
    let host = world.host()
    for number in 0..<SimulatorStreamHost.maximumSessions {
      _ = try await world.started(as: .viewer(number), on: host)
    }

    let extra = await host.handle(try await world.start(as: .macBook, on: host))
    #expect(extra.status == "busy" && extra.message == "Too many panes are showing simulators on this Mac.")
    #expect(host.sessionCount == SimulatorStreamHost.maximumSessions)
  }

  @Test func aStopWithoutATokenEndsOnlyTheStartItNames() async throws {
    let world = World()
    let host = world.host()
    let first = try await world.start(as: .macBook, on: host)
    _ = await host.handle(first)
    let second = try await world.start(as: .macBook, on: host)
    _ = await host.handle(second)

    _ = await host.handle(world.following(first, .stop, session: nil))
    #expect(host.sessionCount == 1)

    _ = await host.handle(world.following(second, .stop, session: nil))
    #expect(host.sessionCount == 0)
  }

  @Test func aStopForAStartStillWaitingForTheScreenLeavesNoSessionOrViewerBehind() async throws {
    let world = World()
    world.screenSize = nil
    world.screenGate = TestSignal()
    let host = world.host()
    let start = try await world.start(as: .macBook, on: host)

    let starting = Task { await host.handle(start) }
    await world.screenAwaited.wait()
    _ = await host.handle(world.following(start, .stop, session: nil))
    world.devices[0].screenSize = CGSize(width: 402, height: 874)
    world.screenGate?.signal()

    #expect(await starting.value.status == "stopped")
    #expect(host.sessionCount == 0 && world.peers.isEmpty && world.devices[0].isClosed)
  }

  @Test func whenTheSimulatorShutsDownAnAppIsToldThereIsNothingToView() async throws {
    let world = World()
    let host = world.host()
    let started = try await world.started(on: host)

    world.booted = []
    let app = await host.handle(world.following(started, .heartbeat))

    #expect(app.status == "stopped" && app.message == Self.shutDown && app.reason == .nothingToView)
    #expect(host.sessionCount == 0 && world.devices.allSatisfy(\.isClosed))
  }

  @Test func aViewerWithoutAnAppIdentityIsToldToUpdateAndNothingStarts() async throws {
    let world = World()
    let host = world.host()
    var anonymous = world.request(.capabilities)
    anonymous.app = nil
    var restart = world.request(.restart)
    restart.app = .macBook

    for request in [anonymous, world.request(.start), world.request(.heartbeat), restart] {
      let reply = await host.handle(request)
      #expect(reply.status == "unavailable" && reply.reason == .updateNeeded && reply.displays.isEmpty)
      #expect(reply.message == "Update Codevisor on this device to view \(ScreenSharingHostService.machineName()).")
    }
    #expect(world.devices.isEmpty && host.sessionCount == 0)
  }

  @Test func aViewerThatStopsHeartbeatingIsExpired() async throws {
    let world = World()
    let host = world.host()
    let started = try await world.started(on: host)

    world.clock += SimulatorStreamHost.lifetime + 1

    #expect(await host.handle(world.following(started, .heartbeat)).status == "stopped")
    #expect(world.peers.first?.isClosed == true && world.devices.first?.isClosed == true)
  }

  @Test func theDevicesStateReachesItsViewersAndTheirInputReachesTheDevice() async throws {
    let world = World()
    let host = world.host()
    _ = try await world.started(on: host)
    let peer = try #require(world.peers.first)
    let device = try #require(world.devices.first)
    var states: [ScreenSharingSimulatorState] = []
    peer.viewer.onMessage = { if case .state(let state) = $0 { states.append(state) } }

    peer.channel.onAvailabilityChanged?(true)
    device.state = ScreenSharingSimulatorState(orientation: .landscapeLeft)
    device.onChange?()
    peer.viewer.send(.button(name: "home", down: true))

    #expect(states.map(\.orientation) == [.portrait, .landscapeLeft])
    #expect(device.received == [.button(name: "home", down: true)])
  }
}
