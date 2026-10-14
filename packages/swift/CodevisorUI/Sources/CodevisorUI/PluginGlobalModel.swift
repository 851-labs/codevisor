import CodevisorCore
import Foundation
import Observation

public struct PluginMachineBinding: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct PluginFleetEntry: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var version: String?
  public var iconPath: String?
  public var setting: PluginFleet.Setting?
  public var localOnlyMachines: [PluginMachineBinding] = []
  public var sourceMachineId: String?
  public var updateAvailableVersion: String?
  public var canRestore: Bool
  public var openPaneCount: Int
  public var ageRating: Int? = nil
  public var source: String = "managed"
  public var pathByMachine: [String: String] = [:]

  public var isLocalOnly: Bool { !localOnlyMachines.isEmpty }

  public var localOnlyKind: String {
    source == "linked" ? "Linked checkout" : "Local-path install"
  }
}

@MainActor @Observable
public final class PluginGlobalModel {
  public internal(set) var catalog: [String: ServerPluginSummary] = [:]
  public internal(set) var catalogMachineId: [String: String] = [:]
  public internal(set) var pathsByPlugin: [String: [String: String]] = [:]
  public internal(set) var updates: [String: ServerPluginUpdateStatus] = [:]
  public internal(set) var localOnly: [String: [PluginMachineBinding]] = [:]
  public var isLoading = true
  public var loadFailed = false
  public var actionError: String?

  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored private var answered = false
  @ObservationIgnored private var answers: [String: (machine: CodevisorMachine, plugins: [ServerPluginSummary])] = [:]
  public private(set) var pendingEnabled: [String: Bool] = [:]

  public init() {}

  public func scheduleReload(in environment: AppEnvironment) {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await self?.load(in: environment)
    }
  }

  public func entries(_ sync: ConfigSync) -> [PluginFleetEntry] {
    var result: [String: PluginFleetEntry] = [:]
    for setting in PluginFleet.settings(sync) {
      let summary = catalog[setting.id]
      result[setting.id] = PluginFleetEntry(
        id: setting.id,
        name: summary?.name ?? setting.id,
        version: summary?.version,
        iconPath: summary?.iconPath,
        setting: setting,
        sourceMachineId: catalogMachineId[setting.id],
        updateAvailableVersion: updateVersion(for: setting.id),
        canRestore: summary?.canRestore ?? false,
        openPaneCount: summary?.openPaneCount ?? 0,
        ageRating: summary?.ageRating,
        source: summary?.source ?? "managed",
        pathByMachine: pathsByPlugin[setting.id] ?? [:])
    }
    for (pluginId, machines) in localOnly where result[pluginId] == nil {
      let summary = catalog[pluginId]
      result[pluginId] = PluginFleetEntry(
        id: pluginId,
        name: summary?.name ?? pluginId,
        version: summary?.version,
        iconPath: summary?.iconPath,
        setting: nil,
        localOnlyMachines: machines,
        sourceMachineId: machines.first?.id,
        updateAvailableVersion: updateVersion(for: pluginId),
        canRestore: summary?.canRestore ?? false,
        openPaneCount: summary?.openPaneCount ?? 0,
        ageRating: summary?.ageRating,
        source: summary?.source ?? "linked",
        pathByMachine: pathsByPlugin[pluginId] ?? [:])
    }
    return result.values.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  public func machineOnlyEntries(_ sync: ConfigSync, machineId: String) -> [PluginFleetEntry] {
    entries(sync).filter { entry in
      entry.localOnlyMachines.contains { $0.id == machineId }
    }
  }

  private func updateVersion(for pluginId: String) -> String? {
    guard let status = updates[pluginId], status.state == .available else { return nil }
    return status.registryVersion
  }

  public func load(in environment: AppEnvironment) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    defer { if generation == loadGeneration { isLoading = false } }
    answered = false
    sweepAnswered = []
    answerOrder = environment.machines.allMachines.map(\.id)
    let probes = environment.machines.allMachines.map { machine in
      let client = environment.machines.client(for: machine.id)
      return Task { @MainActor [weak self] in
        let plugins = try? await client.listPlugins()
        guard let self, generation == self.loadGeneration, let plugins else { return }
        self.sweepAnswered.insert(machine.id)
        self.absorb(plugins, from: machine)
      }
    }
    for probe in probes { await probe.value }
    guard generation == loadGeneration else { return }
    let stale = Set(answers.keys).subtracting(sweepAnswered)
    if !stale.isEmpty {
      for machineId in stale { answers[machineId] = nil }
      rebuild(order: environment.machines.allMachines.map(\.id))
    }
    loadFailed = !answered
    await loadUpdates(in: environment)
  }

  private func absorb(_ plugins: [ServerPluginSummary], from machine: CodevisorMachine) {
    answered = true
    loadFailed = false
    answers[machine.id] = (machine, plugins)
    rebuild(order: answerOrder)
  }

  @ObservationIgnored private var answerOrder: [String] = []
  @ObservationIgnored private var sweepAnswered: Set<String> = []

  private func rebuild(order: [String]) {
    answerOrder = order
    var catalog: [String: ServerPluginSummary] = [:]
    var catalogMachineId: [String: String] = [:]
    var localOnly: [String: [PluginMachineBinding]] = [:]
    var pathsByPlugin: [String: [String: String]] = [:]
    let ordered = order.compactMap { answers[$0] } + answers.filter { !order.contains($0.key) }.map(\.value)
    for (machine, plugins) in ordered {
      for plugin in plugins {
        if catalog[plugin.id] == nil {
          catalog[plugin.id] = plugin
          catalogMachineId[plugin.id] = machine.id
        }
        pathsByPlugin[plugin.id, default: [:]][machine.id] = plugin.path
        if plugin.source != "managed" {
          localOnly[plugin.id, default: []]
            .append(PluginMachineBinding(id: machine.id, name: machine.name))
        }
      }
    }
    self.catalog = catalog
    self.catalogMachineId = catalogMachineId
    self.localOnly = localOnly
    self.pathsByPlugin = pathsByPlugin
  }

  public func isEnabled(pluginId: String, on machineId: String) -> Bool {
    pendingEnabled["\(pluginId)|\(machineId)"]
      ?? answers[machineId]?.plugins.first { $0.id == pluginId }?.isEnabled
      ?? catalog[pluginId]?.isEnabled ?? true
  }

  public func setEnabled(pluginId: String, on machineId: String, enabled: Bool, in environment: AppEnvironment) async {
    let key = "\(pluginId)|\(machineId)"
    pendingEnabled[key] = enabled
    do {
      _ = try await environment.machines.client(for: machineId)
        .setPluginEnabled(pluginId: pluginId, enabled: enabled)
      actionError = nil
      await load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
    if pendingEnabled[key] == enabled { pendingEnabled[key] = nil }
  }

  private func loadUpdates(in environment: AppEnvironment) async {
    let probes = environment.machines.allMachines.map { machine in
      let client = environment.machines.client(for: machine.id)
      return Task { @MainActor [weak self] in
        let reported = try? await client.listPluginUpdates()
        guard let self, let reported else { return }
        for status in reported where self.updates[status.pluginId] == nil {
          self.updates[status.pluginId] = status
        }
      }
    }
    for probe in probes { await probe.value }
  }
}
