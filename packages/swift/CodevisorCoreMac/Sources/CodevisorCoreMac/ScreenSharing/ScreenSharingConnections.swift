import AppKit
import Foundation
import Observation
import ScreenSharingConnection

@MainActor
public final class ScreenSharingConnections {
  private struct Tracked {
    let connection: ScreenSharingConnection
    var wasReady: Bool
  }

  private let source: ScreenSharingConnectionsSource
  private let manager: ScreenSharingConnectionManager
  private let wakeCenter: NotificationCenter
  private var wakeObserver: (any NSObjectProtocol)?
  private var tracked: [String: Tracked] = [:]
  private var shownWorkspaces: [String: UUID] = [:]
  private var observation = 0

  public init(
    source: ScreenSharingConnectionsSource, clock: ScreenSharingConnectionClock = .live,
    wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
  ) {
    self.source = source
    self.wakeCenter = wakeCenter
    manager = ScreenSharingConnectionManager(clock: clock)
    wakeObserver = wakeCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.manager.systemWoke() }
    }
  }

  isolated deinit {
    wakeObserver.map(wakeCenter.removeObserver)
    manager.shutdown()
  }

  public func connection(for machineId: String) throws -> ScreenSharingConnection {
    if let existing = tracked[machineId] { return existing.connection }

    let connection = manager.connection(for: try machine(machineId))
    tracked[machineId] = Tracked(connection: connection, wasReady: source.isReady(machineId))
    observe()
    return connection
  }

  public func surfaceShown(inWorkspace workspaceId: UUID, onMachine machineId: String) {
    shownWorkspaces[machineId] = workspaceId
    manager.workspaceAppeared(machineId)
  }

  public func shutdown() {
    tracked = [:]
    manager.shutdown()
  }

  private func observe() {
    observation += 1
    let current = observation
    withObservationTracking {
      reconcile()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.observation == current else { return }

        self.observe()
      }
    }
  }

  private func reconcile() {
    let known = source.machineIds()
    for machineId in tracked.keys where !known.contains(machineId) { remove(machineId) }
    for machineId in tracked.keys { noteReadiness(of: machineId) }
  }

  private func remove(_ machineId: String) {
    tracked[machineId] = nil
    shownWorkspaces[machineId] = nil
    manager.remove(machineId)
  }

  private func noteReadiness(of machineId: String) {
    let isReady = source.isReady(machineId)
    let cameOnline = isReady && tracked[machineId]?.wasReady == false
    tracked[machineId]?.wasReady = isReady
    if cameOnline { manager.machineCameOnline(machineId) }
  }

  private func machine(_ machineId: String) throws -> ScreenSharingMachine {
    let signer = try source.signer()
    let (channel, openVNC) = (source.channel, source.openVNC)
    return ScreenSharingMachine(
      id: machineId, channel: { channel(machineId) }, connector: source.connector(), appName: source.appName(),
      signer: signer, installId: try ScreenSharingInstallIdentity.id(forKey: signer.key),
      liveWorkspace: { [weak self] in self?.liveWorkspace(on: machineId) },
      presentsTiles: true,
      makeVNCTransport: { displayId, arbitratedByServer in
        ScreenSharingVNCTransport(
          open: { try await openVNC(machineId, displayId) }, arbitratedByServer: arbitratedByServer)
      })
  }

  private func liveWorkspace(on machineId: String) -> UUID? {
    let live = source.workspaces().filter { $0.serverId == machineId && !$0.isArchived && !$0.isDraft }
    let shown = live.first { $0.id == shownWorkspaces[machineId] }
    return (shown ?? live.first)?.id
  }
}
