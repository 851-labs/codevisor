import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
final class ConnectionHarness {
  static let machineId = "croissant"
  static let appName = "Alexandru's MacBook Pro"

  let clock = TestClock()
  var host: FakeHost
  let media = FakeMedia()
  let signer = FakeSigner()
  let manager: ScreenSharingConnectionManager
  let installId = UUID()
  var makeVNCTransport: ScreenSharingMachine.MakeVNCTransport?
  var target: String?
  var machineReady = false
  private(set) var userAsks = 0
  var heartbeatInterval = ScreenSharingConnectionDeadlines.heartbeatInterval
  private var surfaces: [ScreenSharingSurface] = []
  private var startedSessions = 0
  private var eightSecondSleeps = 0

  init(host: FakeHost = FakeHost()) {
    self.host = host
    manager = ScreenSharingConnectionManager(clock: ScreenSharingConnectionClock(clock))
  }

  var machine: ScreenSharingMachine {
    var machine = ScreenSharingMachine(
      id: Self.machineId, channel: { [weak self, host] in self?.host ?? host }, connector: media.connector,
      appName: Self.appName, signer: signer.signer, installId: installId,
      makeVNCTransport: makeVNCTransport)
    machine.target = target
    machine.isReady = { [weak self] in self?.machineReady ?? false }
    machine.userAsked = { [weak self] in self?.userAsks += 1 }
    machine.heartbeatInterval = heartbeatInterval
    return machine
  }

  var connection: ScreenSharingConnection { manager.connection(for: machine) }

  @discardableResult
  func show(_ kind: ScreenSharingSurfaceKind = .tab) -> ScreenSharingSurface {
    let surface = connection.attach(kind)
    surfaces.append(surface)
    surface.setOnScreen(true)
    return surface
  }

  @discardableResult
  func open(_ kind: ScreenSharingSurfaceKind) -> ScreenSharingSurface {
    let surface = connection.attach(kind)
    surfaces.append(surface)
    surface.openedByUser()
    surface.setOnScreen(true)
    return surface
  }

  func startedSession() async -> LoopbackSession {
    startedSessions += 1
    let index = startedSessions - 1
    await awaitObserved { media.sessions.count > index && media.sessions[index].tokens.count == 1 }
    await eightSecondSleepScheduled()
    return media.sessions[index]
  }

  @discardableResult
  func goLive() async -> LoopbackSession {
    let session = await startedSession()
    session.host.deliverFrame(identity: 1)
    await awaitObserved { connection.state == .live }
    return session
  }

  func elapse(_ duration: Duration) async {
    await clock.waitForSleep(duration)
    clock.advance(by: duration)
  }

  func tick(after wait: Duration? = nil) async {
    clock.advance(by: wait ?? heartbeatInterval)
    await eightSecondSleepScheduled()
  }

  func beat(after wait: Duration? = nil) async {
    let answered = host.completed(.heartbeat)
    await tick(after: wait ?? heartbeatInterval)
    await awaitObserved { host.completed(.heartbeat) == answered + 1 }
  }

  func stayLive(for duration: Duration) async {
    var remaining = duration
    while remaining >= heartbeatInterval {
      await beat()
      remaining -= heartbeatInterval
    }
    clock.advance(by: remaining)
  }

  func elapseRetryWait(_ wait: Duration) async {
    if wait == heartbeatInterval {
      await eightSecondSleepScheduled()
    } else {
      await clock.waitForSleep(wait)
    }
    clock.advance(by: wait)
  }

  func useUpTheTries(failingAt operation: FakeHost.Operation, beforeTry: (Int) -> Void = { _ in }) async {
    let before = host.requests(operation).count
    host.hold(operation)
    media.sessions.last?.host.report(connection: "failed")
    for (index, wait) in ScreenSharingRetryPolicy.waits.dropFirst().enumerated() {
      await awaitObserved { host.requests(operation).count == before + index + 1 }
      beforeTry(index)
      await clock.waitForSleep(ScreenSharingConnectionDeadlines.stillConnectingHint)
      let earlierWaits = clock.requestCount(wait)
      host.release(operation)
      host.hold(operation)
      await clock.waitForSleep(wait, count: earlierWaits + 1)
      clock.advance(by: wait - .milliseconds(1))
      #expect(host.requests(operation).count == before + index + 1)
      #expect(connection.state == .reconnecting)
      clock.advance(by: .milliseconds(1))
    }
    await awaitObserved { host.requests(operation).count == before + ScreenSharingRetryPolicy.waits.count }
    host.release(operation)
  }

  func settle(_ state: ScreenSharingConnectionState) async {
    await awaitObserved { connection.state == state }
  }

  func noTimersLeft() async {
    await clock.changed.cancellableWait { clock.pendingCount == 0 }
  }

  func eightSecondSleepScheduled() async {
    eightSecondSleeps += 1
    await clock.waitForSleep(heartbeatInterval, count: eightSecondSleeps)
  }

  isolated deinit {
    host.releaseEverything()
    manager.shutdown()
  }
}
