import CodevisorCore
import Foundation
import Observation
import ScreenSharing
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
  }

  private let manager: ScreenSharingConnectionManager
  private let now: () -> ContinuousClock.Instant
  private let preferences: ScreenSharingMachinePreferences
  private let appName: String
  private var models: [String: ScreenSharingPaneModel] = [:]
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
    for machineId: String, seedDisplayId: String?, environment: AppEnvironment
  ) -> ScreenSharingPaneModel? {
    model(for: machineId, seedDisplayId: seedDisplayId, sources: ScreenSharingDesktopSources(environment: environment))
  }

  func model(
    for machineId: String, seedDisplayId: String?, sources: ScreenSharingDesktopSources
  ) -> ScreenSharingPaneModel? {
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
    onMachine machineId: String, target: String, environment: AppEnvironment
  ) -> ScreenSharingConnection? {
    let sources = ScreenSharingDesktopSources(environment: environment)
    return targetConnection(onMachine: machineId, target: target, sources: sources)
  }

  func targetConnection(
    onMachine machineId: String, target: String, sources: ScreenSharingDesktopSources
  ) -> ScreenSharingConnection? {
    guard sources.machineName(machineId) != nil, var machine = machine(machineId, sources) else { return nil }

    machine.target = target
    machine.makeVNCTransport = nil
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
      signer: signer, installId: installId, makeVNCTransport: makeVNCTransport(machineId, sources))
    machine.isReady = { sources.isReady(machineId) }
    machine.userAsked = { sources.userAsked(machineId) }
    return machine
  }

  private func makeVNCTransport(
    _ machineId: String, _ sources: ScreenSharingDesktopSources
  ) -> ScreenSharingMachine.MakeVNCTransport? {
    guard let openSocket = sources.openVNCSocket else { return nil }

    return { [appName] displayId, arbitratedByServer in
      ScreenSharingVNCTransport(
        open: {
          let relay = RFBWebSocketTransport(socket: try await openSocket(machineId, displayId))
          return try await VNCConnection.open(transport: relay, password: nil, serverDrawsPointer: true)
        }, arbitratedByServer: arbitratedByServer, viewerName: appName, scroll: .touch)
    }
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
      Signals(machineExists: sources.machineName(machineId) != nil, isReady: sources.isReady(machineId))
    } onChange: { [weak self] in
      Task { @MainActor in self?.watch(machineId, sources) }
    }
    apply(now, to: machineId)
  }

  private func apply(_ now: Signals, to machineId: String) {
    let before = signals.updateValue(now, forKey: machineId)
    guard now.machineExists else { return forget(machineId) }

    if now.isReady, before?.isReady == false { manager.machineCameOnline(machineId) }
  }

  public func removeAll() {
    for machineId in Array(models.keys) + Array(watching) { forget(machineId) }
  }

  private func forget(_ machineId: String) {
    models[machineId] = nil
    targetMachines.remove(machineId)
    watching.remove(machineId)
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
