import CodevisorCore
import Foundation
import Observation

/// A machine a machine-bound plugin actually lives on. A named type rather
/// than a tuple so the entry stays Equatable and SwiftUI can diff it.
public struct PluginMachineBinding: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// One plugin as the fleet list shows it: the fleet's wish where there is
/// one, plus whatever any machine could tell us about the plugin itself
/// (name, version, icon — none of which the `plugins` namespace carries).
public struct PluginFleetEntry: Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var version: String?
  public var iconPath: String?
  /// Nil for a plugin no machine reports and no entry describes.
  public var setting: PluginFleet.Setting?
  /// The machines a linked/local-path plugin lives on; empty when it syncs.
  /// A dev checkout can be linked on more than one machine, so the row must
  /// not pick one of them and call it the only place.
  public var localOnlyMachines: [PluginMachineBinding] = []
  /// The machine whose copy supplied the display metadata and can serve the icon.
  public var sourceMachineId: String?
  public var updateAvailableVersion: String?
  public var canRestore: Bool
  public var openPaneCount: Int
  /// The publisher's rating, which gates updating and restoring on iOS.
  public var ageRating: Int? = nil
  /// managed | linked, from whichever machine described it.
  public var source: String = "managed"
  /// Where the plugin sits on each machine that has it — what "Reveal in
  /// Finder" needs, and the only reason the old machine pages had to exist.
  public var pathByMachine: [String: String] = [:]

  public var isLocalOnly: Bool { !localOnlyMachines.isEmpty }

  /// What kind of unshareable install this is — the machine it lives on is
  /// already the section it sits in, so the row says what rather than where.
  public var localOnlyKind: String {
    source == "linked" ? "Linked checkout" : "Local-path install"
  }
}

/// Shared state for the plugin fleet list: the merged catalog across every
/// machine, plus the update statuses that let an entry row say "1.4.0 ·
/// Update available" without opening a machine page.
@MainActor @Observable
public final class PluginGlobalModel {
  public internal(set) var catalog: [String: ServerPluginSummary] = [:]
  public internal(set) var catalogMachineId: [String: String] = [:]
  public internal(set) var pathsByPlugin: [String: [String: String]] = [:]
  public internal(set) var updates: [String: ServerPluginUpdateStatus] = [:]
  /// Machines that reported a plugin only they have, keyed by plugin id.
  public internal(set) var localOnly: [String: [PluginMachineBinding]] = [:]
  public var isLoading = true
  public var loadFailed = false
  public var actionError: String?

  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  /// Discards answers from a sweep that a newer one has replaced.
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored private var answered = false

  public init() {}

  /// Coalesces bursts of state events into one refetch. A machine that
  /// crashes and restarts a plugin, or settles three MCP connections in a
  /// row, must not cost one list call per machine per event.
  public func scheduleReload(in environment: AppEnvironment) {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await self?.load(in: environment)
    }
  }

  /// Every plugin the list shows: the fleet's desired set, then anything a
  /// machine has that never syncs. Sorted by name so rows keep their place.
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

  /// The machine-bound plugins on one machine, in name order.
  public func machineOnlyEntries(_ sync: ConfigSync, machineId: String) -> [PluginFleetEntry] {
    entries(sync).filter { entry in
      entry.localOnlyMachines.contains { $0.id == machineId }
    }
  }

  private func updateVersion(for pluginId: String) -> String? {
    guard let status = updates[pluginId], status.state == .available else { return nil }
    return status.registryVersion
  }

  /// Fans the light list out across every machine and merges by plugin id.
  /// A machine that can't answer is skipped, not fatal: one unreachable
  /// machine must never blank the fleet's list.
  /// Asks every machine at once and publishes each answer as it lands. A
  /// sequential sweep cost the sum of every machine's timeout and showed
  /// nothing until the slowest replied.
  public func load(in environment: AppEnvironment) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    defer { if generation == loadGeneration { isLoading = false } }
    catalog = [:]
    catalogMachineId = [:]
    localOnly = [:]
    pathsByPlugin = [:]
    answered = false
    // Every machine is asked at once and publishes its own answer the moment
    // it lands, so one unreachable machine never holds the page on
    // "Loading…" while the others sit ready.
    let probes = environment.machines.allMachines.map { machine in
      let client = environment.machines.client(for: machine.id)
      return Task { @MainActor [weak self] in
        let plugins = try? await client.listPlugins()
        guard let self, generation == self.loadGeneration, let plugins else { return }
        self.absorb(plugins, from: machine)
      }
    }
    for probe in probes { await probe.value }
    guard generation == loadGeneration else { return }
    loadFailed = !answered
    await loadUpdates(in: environment)
  }

  private func absorb(_ plugins: [ServerPluginSummary], from machine: CodevisorMachine) {
    answered = true
    loadFailed = false
    for plugin in plugins {
      if catalog[plugin.id] == nil {
        catalog[plugin.id] = plugin
        catalogMachineId[plugin.id] = machine.id
      }
      pathsByPlugin[plugin.id, default: [:]][machine.id] = plugin.path
      // A linked/dev checkout or a local-path install never reaches the
      // fleet; its row sits under the machine that actually has it.
      if plugin.source != "managed" {
        localOnly[plugin.id, default: []]
          .append(PluginMachineBinding(id: machine.id, name: machine.name))
      }
    }
  }

  /// Update checks hit the plugin registry over the network, so they run
  /// after the list is already on screen and never hold it up.
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
