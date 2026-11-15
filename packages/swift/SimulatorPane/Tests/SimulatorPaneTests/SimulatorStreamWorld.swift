import CodevisorClient
import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import ScreenSharingV2

@testable import SimulatorPane

@MainActor
@Observable
final class SimulatorStreamWorld {
  static let machineId = "croissant"
  static let udid = "8C2D33A1-7E5B-4F0A-9C3D-2B1E4F6A7D90"
  static let target = "simulator:\(udid)"
  static let limit = "Too many panes are showing simulators on this Mac."

  let host: FakeHost
  private(set) var sessions: [SimulatorTestSession] = []
  private(set) var ended: [String] = []
  @ObservationIgnored let clock = TestClock()
  @ObservationIgnored let signer = FakeSigner()
  @ObservationIgnored let manager: ScreenSharingConnectionManager
  @ObservationIgnored let streams = SimulatorStreams()
  @ObservationIgnored private let installId = UUID()
  @ObservationIgnored private var beats = 0

  init(oldHost: Bool = false) {
    host = oldHost ? .old() : FakeHost()
    manager = ScreenSharingConnectionManager(clock: ScreenSharingConnectionClock(clock))
  }

  isolated deinit {
    host.releaseEverything()
    manager.shutdown()
  }

  func pane() -> (identity: ScreenSharingLegacyIdentity, stream: SimulatorStream) {
    let identity = ScreenSharingLegacyIdentity(workspaceId: UUID(), paneId: UUID())
    let stream = streams.stream(machineId: Self.machineId, udid: Self.udid, pane: identity, source: source)
    return (identity, stream)
  }

  func show(_ stream: SimulatorStream) {
    stream.start()
    stream.setVisible(true)
  }

  @discardableResult
  func shown() -> SimulatorStream {
    let stream = pane().stream
    show(stream)
    return stream
  }

  @discardableResult
  func goLive(_ stream: SimulatorStream, session index: Int = 0) async -> SimulatorTestSession {
    await awaitObserved { sessions.count > index && sessions[index].isStarted }
    sessions[index].host.deliverFrame(identity: 1)
    await awaitObserved { stream.phase == .streaming }
    return sessions[index]
  }

  func beat() async {
    beats += 1
    await clock.waitForSleep(ScreenSharingConnectionDeadlines.heartbeatInterval, count: beats)
    let answered = host.completed(.heartbeat)
    clock.advance(by: ScreenSharingConnectionDeadlines.heartbeatInterval)
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

  func elapse(_ duration: Duration) async {
    await clock.waitForSleep(duration)
    clock.advance(by: duration)
  }

  private var source: SimulatorStreamSource {
    SimulatorStreamSource(
      machineName: Self.machineId,
      connection: { [unowned self] target, attachedPane in
        var machine = ScreenSharingMachine(
          id: Self.machineId, channel: { [host] in host }, connector: connector,
          appName: "Alexandru's MacBook Pro", signer: signer.signer, installId: installId, liveWorkspace: { nil })
        machine.target = target
        machine.attachedPane = attachedPane
        return manager.connection(for: machine)
      },
      end: { [unowned self] target in
        ended.append(target)
        manager.remove(Self.machineId, target: target)
      })
  }

  private var connector: ScreenSharingV2Connector {
    ScreenSharingV2Connector(
      address: { FakeMedia.address },
      connect: { [unowned self] _ in
        let session = SimulatorTestSession()
        sessions.append(session)
        return session
      })
  }
}
