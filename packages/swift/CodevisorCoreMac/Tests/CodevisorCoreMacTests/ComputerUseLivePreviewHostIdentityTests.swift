import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore
@testable import CodevisorCoreMac

@MainActor
@Suite("Computer Use live preview host, app-owned sessions")
struct ComputerUseLivePreviewHostIdentityTests {
  typealias World = ComputerUseLivePreviewHostWorld

  static let target = ComputerUseLivePreviewHostTests.target
  static let stoppedControlling = "The agent stopped controlling the app."

  static func expectUpdateReply(_ reply: ServerScreenSharingReply) {
    #expect(reply.status == "unavailable" && reply.reason == .updateNeeded && reply.displays.isEmpty)
    #expect(reply.message == "Update Codevisor on this device to view \(ScreenSharingHostService.machineName()).")
    #expect(reply.abilities == nil && reply.challenge == nil && reply.media == nil && reply.session == nil)
  }

  static func anonymous(_ request: ServerScreenSharingRequest) -> ServerScreenSharingRequest {
    var request = request
    request.app = nil
    return request
  }

  @Test func anAppIsOfferedAppSessionsAndAChallengeAndAnOldViewerIsToldToUpdate() async {
    let world = World()
    world.activityState = .active
    let host = world.host()

    Self.expectUpdateReply(await host.handle(Self.anonymous(world.request(.capabilities))))

    let named = await host.handle(world.capabilities(as: .macBook))
    #expect(named.status == "available" && named.abilities == [ServerScreenSharingReply.appSessions])
    #expect(named.challenge?.hostKey == world.hostKey && named.challenge?.nonce.count == 64)
    #expect(named.displays.map(\.id) == [Self.target])
  }

  @Test func refusalsCarryAReasonForAnApp() async {
    let world = World()
    let host = world.host()

    let idle = await host.handle(world.capabilities(as: .macBook))
    #expect(idle.status == "unavailable" && idle.reason == .nothingToView && idle.challenge == nil)
    #expect(idle.message == "The agent is not controlling an app right now.")

    world.activityState = .active
    world.access = false
    #expect(await host.handle(world.capabilities(as: .macBook)).reason == .permissionMissing)
  }

  @Test func aSignedStartIsGrantedASessionTokenThatHeartbeatsAndStopsIt() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()

    let start = try await world.start(as: .macBook, on: host)
    let granted = await host.handle(start)
    let token = try #require(granted.session)
    #expect(granted.status == "connecting" && granted.media == ComputerUseLivePreviewHostTests.grant)
    #expect(token.count == 64 && world.requestedMedia == [.init(viewerEndpointId: ServerScreenSharingApp.macBook.key)])

    #expect(await host.handle(world.following(start, .heartbeat, session: token)).status == "connecting")
    #expect(
      await host.handle(world.following(start, .stop, session: String(repeating: "0", count: 64))).status == "stopped")
    #expect(host.sessionCount == 1)

    #expect(await host.handle(world.following(start, .stop, session: token)).status == "stopped")
    #expect(host.sessionCount == 0 && world.peers.allSatisfy(\.closed))
    let after = await host.handle(world.following(start, .heartbeat, session: token))
    #expect(after.status == "stopped" && after.reason == nil)
  }

  @Test func onlyTheSessionsOwnTokenKeepsItAliveAndAnUnidentifiedRequestIsToldToUpdate() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()
    let started = try await world.started(on: host)

    #expect(
      await host.handle(world.following(started.start, .heartbeat, session: String(repeating: "0", count: 64)))
        .status == "stopped")
    Self.expectUpdateReply(await host.handle(world.following(started.start, .heartbeat, session: nil)))
    Self.expectUpdateReply(await host.handle(Self.anonymous(world.request(.start))))
    var restart = world.request(.restart)
    restart.app = .macBook
    Self.expectUpdateReply(await host.handle(restart))
    #expect(await host.handle(world.following(started, .heartbeat)).status == "connecting")
    #expect(host.sessionCount == 1 && world.peers.count == 1)
  }

  @Test func aStartWhoseKeyIsNotProvenCreatesNothingAndGetsAFreshChallenge() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()

    var unsigned = try await world.start(as: .macBook, on: host)
    unsigned.proof = .init(nonce: String(repeating: "0", count: 64), signature: String(repeating: "0", count: 128))
    var forged = try await world.start(as: .macBook, on: host)
    forged.proof = try ServerScreenSharingProof(
      of: forged, answering: try #require(await host.handle(world.capabilities(as: .macBook)).challenge),
      signer: ServerScreenSharingApp.iPhone.signer)
    var retargeted = try await world.start(as: .macBook, on: host)
    retargeted.displayId = "computer-use:\(UUID().uuidString.lowercased())"
    var reopened = try await world.start(as: .macBook, on: host)
    reopened.intent = .open

    for request in [unsigned, forged, retargeted, reopened] {
      let reply = await host.handle(request)
      #expect(reply.status == "failed" && reply.reason == .proofRejected)
      #expect(reply.media == nil && reply.session == nil && reply.challenge?.nonce.count == 64)
    }
    #expect(world.peers.isEmpty && host.sessionCount == 0)
  }

  @Test func aSignedStartWorksOnceAndOnlyForTheKeyThatReceivesTheVideo() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()

    let start = try await world.start(as: .macBook, on: host)
    #expect(await host.handle(start).status == "connecting")
    #expect(await host.handle(start).reason == .proofRejected)

    var elsewhere = try await world.start(as: .iPhone, on: host)
    elsewhere.media = .init(endpointId: ServerScreenSharingApp.macBook.key, relayUrl: nil, directAddrs: [])
    let refused = await host.handle(elsewhere)
    #expect(refused.status == "failed" && refused.media == nil)
    #expect(host.sessionCount == 1 && world.peers.count == 1)
  }

  @Test func theProofCoversTheTargetAsSentAndTheOwnerIsTheSessionItNames() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()
    let shouted = "computer-use:\(ComputerUseLivePreviewHostTests.session.uppercased())"

    let first = await host.handle(try await world.start(as: .macBook, on: host, target: shouted))
    let second = await host.handle(try await world.start(as: .macBook, on: host))

    #expect(first.status == "connecting" && second.status == "connecting")
    #expect(host.sessionCount == 1 && world.peers.map(\.closed) == [true, false])
  }

  @Test func theSameAppReplacesItsOwnSessionAndAnotherAppGetsItsOwn() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()

    let first = try await world.start(as: .macBook, on: host)
    let firstToken = await host.handle(first).session
    let second = try await world.start(as: .macBook, on: host)
    let secondToken = await host.handle(second).session
    #expect(host.sessionCount == 1 && world.peers.map(\.closed) == [true, false])
    #expect(await host.handle(world.following(first, .heartbeat, session: firstToken)).status == "stopped")

    let phone = try await world.start(as: .iPhone, on: host)
    #expect(await host.handle(phone).status == "connecting")
    #expect(host.sessionCount == 2 && world.peers.map(\.closed) == [true, false, false])
    #expect(await host.handle(world.following(second, .heartbeat, session: secondToken)).status == "connecting")
  }

  @Test func theViewerLimitKeepsItsReplyAndAnAppsOwnSessionDoesNotCountTwice() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()
    for number in 1..<ComputerUseLivePreviewHost.maximumSessions {
      _ = try await world.started(as: .viewer(number), on: host)
    }

    #expect(await host.handle(try await world.start(as: .macBook, on: host)).status == "connecting")
    #expect(await host.handle(try await world.start(as: .macBook, on: host)).status == "connecting")

    let extra = await host.handle(try await world.start(as: .iPhone, on: host))
    #expect(extra.status == "busy" && extra.message == "Too many viewers are watching this agent.")
    #expect(extra.reason == nil && extra.holderName == nil)
    #expect(host.sessionCount == ComputerUseLivePreviewHost.maximumSessions)
  }

  @Test func aStopWithoutATokenEndsOnlyTheStartItNames() async throws {
    let world = World()
    world.activityState = .active
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

  @Test func aStopForAStartStillInFlightLeavesNoSessionBehind() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()
    let start = try await world.start(as: .macBook, on: host)
    world.peerGate = TestSignal()

    let starting = Task { await host.handle(start) }
    await world.peerRequested.wait()
    _ = await host.handle(world.following(start, .stop, session: nil))
    world.peerGate?.signal()

    #expect(await starting.value.status == "stopped")
    #expect(host.sessionCount == 0 && world.peers.allSatisfy(\.closed) && world.attached.isEmpty)
  }

  @Test func whenTheAgentStopsAnAppIsToldThereIsNothingToView() async throws {
    let world = World()
    world.activityState = .active
    let host = world.host()
    let start = try await world.start(as: .macBook, on: host)
    let token = await host.handle(start).session

    world.activityState = .stopped
    let app = await host.handle(world.following(start, .heartbeat, session: token))

    #expect(app.status == "stopped" && app.message == Self.stoppedControlling && app.reason == .nothingToView)
  }

  @Test func aSessionTheHostEndedWhenTheAgentStoppedIsRememberedForItsLastSixteenTokens() async throws {
    let world = World()
    let host = world.host()
    var ended: [(start: ServerScreenSharingRequest, token: String?)] = []
    for _ in 0...ScreenSharingStreamIdentity.rememberedEndings {
      world.activityState = .active
      let start = try await world.start(as: .macBook, on: host)
      ended.append((start, await host.handle(start).session))
      world.activityState = .stopped
      host.activityChanged()
    }

    let forgotten = await host.handle(world.following(ended[0].start, .heartbeat, session: ended[0].token))
    let remembered = await host.handle(world.following(ended[1].start, .heartbeat, session: ended[1].token))

    #expect(forgotten.status == "stopped" && forgotten.reason == nil)
    #expect(forgotten.message == "The live view ended on the host Mac.")
    #expect(remembered.status == "stopped" && remembered.message == Self.stoppedControlling)
    #expect(remembered.reason == .nothingToView)
  }
}
