import CodevisorCore
import Foundation
import Observation
import ScreenSharingConnection

#if os(iOS)
  import UIKit
#endif

@MainActor
public final class ScreenSharingDesktops {
  public static let shared = ScreenSharingDesktops()

  struct Signals: Equatable {
    var machineExists: Bool
    var isReady: Bool
    var hasWorkspace: Bool
  }

  private let manager: ScreenSharingConnectionManager
  private let now: () -> ContinuousClock.Instant
  private let preferences: ScreenSharingMachinePreferences
  private let appName: String
  private var models: [String: ScreenSharingPaneModel] = [:]
  private var workspaces: [String: UUID] = [:]
  private var signals: [String: Signals] = [:]
  private var targetMachines: Set<String> = []
  private var watching: Set<String> = []
  private var foreground: (any NSObjectProtocol)?

  init(
    manager: ScreenSharingConnectionManager = ScreenSharingConnectionManager(),
    now: @escaping () -> ContinuousClock.Instant = { .now }, defaults: UserDefaults = .standard,
    appName: String = ScreenSharingDeviceName.current
  ) {
    self.manager = manager
    self.now = now
    self.appName = appName
    preferences = ScreenSharingMachinePreferences(defaults: defaults)
    watchForeground()
  }

  public func model(
    for machineId: String, showing workspaceId: UUID, seedDisplayId: String?, environment: AppEnvironment
  ) -> ScreenSharingPaneModel? {
    model(
      for: machineId, showing: workspaceId, seedDisplayId: seedDisplayId,
      sources: ScreenSharingDesktopSources(environment: environment))
  }

  func model(
    for machineId: String, showing workspaceId: UUID, seedDisplayId: String?, sources: ScreenSharingDesktopSources
  ) -> ScreenSharingPaneModel? {
    remember(workspaceId, on: machineId, sources)
    if let model = models[machineId] { return model }
    guard let name = sources.machineName(machineId), let machine = machine(machineId, sources) else { return nil }

    let connection = manager.connection(for: machine)
    connection.preferredDisplayId = preferences.preferredDisplay(machineId: machineId) ?? seedDisplayId
    let model = ScreenSharingPaneModel(connection: connection, machineName: name, now: now) { [preferences] in
      preferences.setPreferredDisplay($0, machineId: machineId)
    }
    models[machineId] = model
    startWatching(machineId, sources)
    return model
  }

  public func targetConnection(
    onMachine machineId: String, target: String,
    attachedPane: @escaping @MainActor () -> ScreenSharingLegacyIdentity?, environment: AppEnvironment
  ) -> ScreenSharingConnection? {
    targetConnection(
      onMachine: machineId, target: target, attachedPane: attachedPane,
      sources: ScreenSharingDesktopSources(environment: environment))
  }

  func targetConnection(
    onMachine machineId: String, target: String,
    attachedPane: @escaping @MainActor () -> ScreenSharingLegacyIdentity?, sources: ScreenSharingDesktopSources
  ) -> ScreenSharingConnection? {
    guard sources.machineName(machineId) != nil, var machine = machine(machineId, sources) else { return nil }

    machine.target = target
    machine.attachedPane = attachedPane
    targetMachines.insert(machineId)
    startWatching(machineId, sources)
    return manager.connection(for: machine)
  }

  public func endTargetConnection(onMachine machineId: String, target: String) {
    manager.remove(machineId, target: target)
  }

  func returnedToForeground() {
    manager.systemWoke()
  }

  private func machine(_ machineId: String, _ sources: ScreenSharingDesktopSources) -> ScreenSharingMachine? {
    guard let signer = try? sources.signer(), let installId = Self.installId(forKey: signer.key) else { return nil }

    var machine = ScreenSharingMachine(
      id: machineId, channel: { sources.channel(machineId) }, connector: sources.connector, appName: appName,
      signer: signer, installId: installId,
      liveWorkspace: { [weak self] in self?.liveWorkspace(on: machineId, sources) })
    machine.isReady = { sources.isReady(machineId) }
    return machine
  }

  private func remember(_ shown: UUID, on machineId: String, _ sources: ScreenSharingDesktopSources) {
    if let remembered = workspaces[machineId], sources.isLive(remembered) { return }

    workspaces[machineId] = shown
  }

  private func liveWorkspace(on machineId: String, _ sources: ScreenSharingDesktopSources) -> UUID? {
    if let remembered = workspaces[machineId], sources.isLive(remembered) { return remembered }

    let found = sources.liveWorkspaces(machineId).first
    workspaces[machineId] = found
    return found
  }

  private func startWatching(_ machineId: String, _ sources: ScreenSharingDesktopSources) {
    guard watching.insert(machineId).inserted else { return }

    watch(machineId, sources)
  }

  private func watch(_ machineId: String, _ sources: ScreenSharingDesktopSources) {
    guard models[machineId] != nil || targetMachines.contains(machineId) else {
      watching.remove(machineId)
      return
    }

    let now = withObservationTracking {
      _ = sources.workspacesRevision()
      return Signals(
        machineExists: sources.machineName(machineId) != nil, isReady: sources.isReady(machineId),
        hasWorkspace: liveWorkspace(on: machineId, sources) != nil)
    } onChange: { [weak self] in
      Task { @MainActor in self?.watch(machineId, sources) }
    }
    apply(now, to: machineId)
  }

  private func apply(_ now: Signals, to machineId: String) {
    let before = signals.updateValue(now, forKey: machineId)
    guard now.machineExists else { return forget(machineId) }

    if now.isReady, before?.isReady == false { manager.machineCameOnline(machineId) }
    if now.hasWorkspace, before?.hasWorkspace == false { manager.workspaceAppeared(machineId) }
  }

  private func forget(_ machineId: String) {
    models[machineId] = nil
    targetMachines.remove(machineId)
    watching.remove(machineId)
    workspaces[machineId] = nil
    signals[machineId] = nil
    manager.remove(machineId)
  }

  isolated deinit {
    if let foreground { NotificationCenter.default.removeObserver(foreground) }
  }

  private func watchForeground() {
    #if os(iOS)
      foreground = NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.returnedToForeground() }
      }
    #endif
  }

  private static func installId(forKey key: String) -> UUID? {
    var digits = Substring(key)
    let groups = [8, 4, 4, 4, 12].map { length in
      defer { digits = digits.dropFirst(length) }
      return digits.prefix(length)
    }
    return UUID(uuidString: groups.joined(separator: "-"))
  }
}
