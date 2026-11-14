import CodevisorTestSupport
import Foundation
import ScreenSharingConnection

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
  var workspaces = [UUID()]
  var makeVNCTransport: ScreenSharingMachine.MakeVNCTransport?
  private var surfaces: [ScreenSharingSurface] = []
  private var startedSessions = 0
  private var eightSecondSleeps = 0

  init(host: FakeHost = FakeHost()) {
    self.host = host
    manager = ScreenSharingConnectionManager(clock: ScreenSharingConnectionClock(clock))
  }

  var machine: ScreenSharingMachine {
    ScreenSharingMachine(
      id: Self.machineId, channel: { [weak self, host] in self?.host ?? host }, connector: media.connector,
      appName: Self.appName, signer: signer.signer, installId: installId,
      liveWorkspace: { [weak self] in self?.workspaces.first },
      makeVNCTransport: makeVNCTransport)
  }

  var connection: ScreenSharingConnection { manager.connection(for: machine) }

  func legacyIdentity(_ workspace: UUID) -> ScreenSharingLegacyIdentity {
    ScreenSharingLegacyIdentity(workspaceId: workspace, installId: installId)
  }

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

  func tick(after wait: Duration = ScreenSharingConnectionDeadlines.heartbeatInterval) async {
    clock.advance(by: wait)
    await eightSecondSleepScheduled()
  }

  func beat(after wait: Duration = ScreenSharingConnectionDeadlines.heartbeatInterval) async {
    let answered = host.completed(.heartbeat)
    await tick(after: wait)
    await awaitObserved { host.completed(.heartbeat) == answered + 1 }
  }

  func stayLive(for duration: Duration) async {
    var remaining = duration
    while remaining >= ScreenSharingConnectionDeadlines.heartbeatInterval {
      await beat()
      remaining -= ScreenSharingConnectionDeadlines.heartbeatInterval
    }
    clock.advance(by: remaining)
  }

  func elapseRetryWait(_ wait: Duration) async {
    if wait == .seconds(8) {
      await eightSecondSleepScheduled()
    } else {
      await clock.waitForSleep(wait)
    }
    clock.advance(by: wait)
  }

  func settle(_ state: ScreenSharingConnectionState) async {
    await awaitObserved { connection.state == state }
  }

  func noTimersLeft() async {
    await clock.changed.cancellableWait { clock.pendingCount == 0 }
  }

  func eightSecondSleepScheduled() async {
    eightSecondSleeps += 1
    await clock.waitForSleep(.seconds(8), count: eightSecondSleeps)
  }

  isolated deinit {
    host.releaseEverything()
    manager.shutdown()
  }
}
