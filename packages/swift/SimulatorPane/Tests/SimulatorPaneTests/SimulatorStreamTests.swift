import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@testable import SimulatorPane

@MainActor
@Suite("Simulator panes on the connection core", .timeLimit(.minutes(1)))
struct SimulatorStreamTests {
  typealias World = SimulatorStreamWorld

  @Test func twoPanesShowOneSimulatorOverOneConnection() async throws {
    let world = World()
    let (first, second) = (world.shown(), world.shown())

    await world.goLive(first)
    await awaitObserved { second.phase == .streaming }

    #expect(world.host.starts.count == 1 && world.sessions.count == 1)
    guard case .video(let one, _)? = first.source, case .video(let other, _)? = second.source else {
      Issue.record("Both panes should have the simulator's video")
      return
    }
    #expect(one !== other && one.isHolding && other.isHolding)
  }

  @Test func everyRequestNamesTheSimulatorAndFollowsTheSessionToken() async {
    let world = World()
    let stream = world.shown()
    await world.goLive(stream)
    await world.beat()

    stream.stop()
    await awaitObserved { world.host.stops.count == 1 }

    let requests = world.host.requests
    #expect(requests.map(\.operation) == [.capabilities, .start, .heartbeat, .stop])
    #expect(requests.allSatisfy { $0.displayId == World.target })
    #expect(requests[1].app != nil && requests[2].session != nil && requests[2].session == requests[3].session)
  }

  @Test func closingOnePaneChangesNothingAndClosingTheLastEndsTheStreamAtOnce() async {
    let world = World()
    let (first, second) = (world.shown(), world.shown())
    await world.goLive(first)

    first.stop()
    #expect(world.ended.isEmpty && second.phase == .streaming && world.host.stops.isEmpty)

    second.stop()
    #expect(world.ended == [World.target])
    await awaitObserved { world.host.stops.count == 1 }

    let later = world.shown()
    await world.goLive(later, session: 1)
    #expect(world.host.starts.count == 2)
  }

  @Test func aPaneLetGoOfWithoutClosingStillEndsTheStreamWhenItIsTheLast() async throws {
    let world = World()
    var stream: SimulatorStream? = world.shown()
    await world.goLive(try #require(stream))

    stream = nil

    #expect(world.ended == [World.target])
    await awaitObserved { world.host.stops.count == 1 }
  }

  @Test func aHiddenPaneKeepsItsStreamForAboutAMinuteThenConnectsAgainWhenShown() async {
    let world = World()
    let stream = world.shown()
    await world.goLive(stream)

    stream.setVisible(false)
    await world.elapse(ScreenSharingConnectionDeadlines.unseenDebounce)
    await world.clock.waitForSleep(ScreenSharingConnectionDeadlines.linger)
    await world.stayLive(for: ScreenSharingConnectionDeadlines.linger - .seconds(1))
    #expect(stream.phase == .streaming && world.host.stops.isEmpty)

    world.clock.advance(by: .seconds(1))
    await awaitObserved { world.host.stops.count == 1 }
    #expect(stream.phase == .connecting && world.ended.isEmpty)

    stream.setVisible(true)
    await world.goLive(stream, session: 1)
    #expect(world.host.starts.count == 2)
  }

  @Test(arguments: [false, true])
  func theSessionLimitShowsTheHostsSentenceWithRetry(oldHost: Bool) async {
    let world = World(oldHost: oldHost)
    world.host.answerEvery(.start, .reply(status: "busy", message: World.limit))
    let stream = world.shown()

    await awaitObserved { stream.phase == .failed(World.limit) }
    #expect(!stream.isWaitingForTheSimulator && world.host.starts.count == 1)

    world.host.answerEvery(.start, nil)
    stream.retry()
    await world.goLive(stream)
    #expect(world.host.starts.count == 2)
  }

  @Test(arguments: [false, true])
  func aSimulatorThatIsStillStartingIsWaitedForAndConnectsWhenItAppears(oldHost: Bool) async {
    let world = World(oldHost: oldHost)
    let reason = oldHost ? nil : "nothing-to-view"
    world.host.answerEvery(
      .capabilities, .reply(status: "starting", message: "The simulator is starting.", reason: reason))
    let stream = world.shown()

    await awaitObserved { stream.isWaitingForTheSimulator }
    #expect(stream.phase == .connecting && world.host.requests.count == 1)

    world.host.answerEvery(.capabilities, nil)
    stream.simulatorAppeared()
    await world.goLive(stream)
    #expect(world.host.starts.count == 1)
  }

  @Test func theDevicesStateReachesEveryPaneAndAPanesInputReachesTheDevice() async {
    let world = World()
    let (first, second) = (world.shown(), world.shown())
    let session = await world.goLive(first)
    var received: [ScreenSharingSimulatorMessage] = []
    session.device.onMessage = { received.append($0) }

    session.device.send(.state(ScreenSharingSimulatorState(orientation: .landscapeLeft)))
    second.send(.button(name: "home", down: true))

    #expect(first.state?.orientation == .landscapeLeft && second.state == first.state)
    #expect(received == [.button(name: "home", down: true)])
  }

  @Test func theDevicesStateSentTheMomentTheSessionStartsIsNotLost() async {
    let world = World()
    world.stateOnStart = ScreenSharingSimulatorState(orientation: .landscapeRight)
    let stream = world.shown()

    await world.goLive(stream)

    #expect(stream.state?.orientation == .landscapeRight)
  }

  @Test func anOldHostIsGivenAPaneThatIsAttachedNowAndTheNextOneWhenThatPaneCloses() async {
    let world = World(oldHost: true)
    let (first, second) = (world.pane(), world.pane())
    world.show(first.stream)
    world.show(second.stream)
    await world.goLive(first.stream)
    #expect(world.host.starts.map(\.paneId) == [first.identity.paneId] && world.host.starts[0].app == nil)

    first.stream.stop()
    world.host.answerNext(.heartbeat, .failure(FakeHost.paneGone))
    await world.beat()
    await world.goLive(second.stream, session: 1)

    #expect(world.host.starts.map(\.paneId) == [first.identity.paneId, second.identity.paneId])
    #expect(world.host.starts[1].workspaceId == second.identity.workspaceId)
  }
}
