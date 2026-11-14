import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting

@testable import ScreenSharingPane

@MainActor
final class DesktopsHarness {
  static let machineId = "croissant"
  static let appName = "Alexandru's iPhone"

  @Observable
  final class World {
    var machineName: String? = "croissant"
    var isReady = true
    var liveWorkspaces = [UUID()]
  }

  @Observable
  final class ControlLog {
    var messages: [ScreenSharingControlMessage] = []
  }

  let clock = TestClock()
  let host: FakeHost
  let media = FakeMedia()
  let signer = FakeSigner()
  let world = World()
  let defaults: UserDefaults
  private let suite = "ScreenSharingDesktopsTests.\(UUID().uuidString)"
  private var managers: [ScreenSharingConnectionManager] = []
  private var views: [UUID] = []
  private var startedSessions = 0
  private(set) lazy var desktops = makeDesktops()

  init(host: FakeHost = FakeHost()) {
    self.host = host
    defaults = UserDefaults(suiteName: suite) ?? .standard
  }

  var sources: ScreenSharingDesktopSources {
    ScreenSharingDesktopSources(
      signer: { [signer] in signer.signer }, channel: { [host] _ in host }, connector: media.connector,
      machineName: { [world] _ in world.machineName }, isReady: { [world] _ in world.isReady },
      isLive: { [world] in world.liveWorkspaces.contains($0) }, liveWorkspaces: { [world] _ in world.liveWorkspaces })
  }

  func makeDesktops() -> ScreenSharingDesktops {
    let manager = ScreenSharingConnectionManager(clock: ScreenSharingConnectionClock(clock))
    managers.append(manager)
    return ScreenSharingDesktops(manager: manager, defaults: defaults, appName: Self.appName)
  }

  func model(
    in desktops: ScreenSharingDesktops? = nil, showing workspace: UUID? = nil, seedDisplayId: String? = nil
  ) -> ScreenSharingPaneModel? {
    (desktops ?? self.desktops).model(
      for: Self.machineId, showing: workspace ?? world.liveWorkspaces[0], seedDisplayId: seedDisplayId,
      sources: sources)
  }

  @discardableResult
  func show(_ model: ScreenSharingPaneModel?) -> UUID {
    let view = UUID()
    model?.setOnScreen(true, for: view)
    return view
  }

  @discardableResult
  func goLive(_ model: ScreenSharingPaneModel?) async -> LoopbackSession {
    startedSessions += 1
    let index = startedSessions - 1
    await awaitObserved { media.sessions.count > index && media.sessions[index].tokens.count == 1 }
    let session = media.sessions[index]
    session.host.deliverFrame(identity: 1)
    await awaitObserved { model?.isViewing == true && model?.viewed?.session === session }
    return session
  }

  func heartbeat() async {
    await clock.waitForSleep(ScreenSharingConnectionDeadlines.heartbeatInterval)
    clock.advance(by: ScreenSharingConnectionDeadlines.heartbeatInterval)
  }

  func controlLog(of session: LoopbackSession) -> ControlLog {
    let log = ControlLog()
    session.host.control?.onMessage = { log.messages.append($0) }
    return log
  }

  isolated deinit {
    host.releaseEverything()
    for manager in managers { manager.shutdown() }
    defaults.removePersistentDomain(forName: suite)
  }
}
