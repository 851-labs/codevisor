import CodevisorTestSupport
import Foundation
import ScreenSharingConnection

@MainActor
final class ConnectionHarness {
  static let machineId = "croissant"
  static let appName = "Alexandru's MacBook Pro"

  let clock = TestClock()
  let host: FakeHost
  let media = FakeMedia()
  let manager: ScreenSharingConnectionManager
  let installId = UUID()
  var workspaces = [UUID()]
  var makeVNCTransport: ScreenSharingMachine.MakeVNCTransport?
  private var startedSessions = 0
  private var eightSecondSleeps = 0

  init(host: FakeHost = FakeHost()) {
    self.host = host
    manager = ScreenSharingConnectionManager(clock: ScreenSharingConnectionClock(clock))
  }

  var machine: ScreenSharingMachine {
    ScreenSharingMachine(
      id: Self.machineId, channel: host, connector: media.connector, appName: Self.appName, installId: installId,
      liveWorkspace: { [weak self] in self?.workspaces.first }, makeVNCTransport: makeVNCTransport)
  }

  var connection: ScreenSharingConnection { manager.connection(for: machine) }

  func legacyIdentity(_ workspace: UUID) -> ScreenSharingLegacyIdentity {
    ScreenSharingLegacyIdentity(workspaceId: workspace, installId: installId)
  }

  func show(_ kind: ScreenSharingSurfaceKind = .tab) -> ScreenSharingSurface {
    let surface = connection.attach(kind)
    surface.setOnScreen(true)
    return surface
  }

  @discardableResult
  func open(_ kind: ScreenSharingSurfaceKind) -> ScreenSharingSurface {
    let surface = connection.attach(kind)
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

  func stayLive(for duration: Duration = ScreenSharingConnectionDeadlines.heartbeatInterval) async {
    clock.advance(by: duration)
    await eightSecondSleepScheduled()
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

  func eightSecondSleepScheduled() async {
    eightSecondSleeps += 1
    await clock.waitForSleep(.seconds(8), count: eightSecondSleeps)
  }

  isolated deinit {
    for operation in [FakeHost.Operation.capabilities, .start, .heartbeat, .stop] { host.release(operation) }
    manager.shutdown()
  }
}
