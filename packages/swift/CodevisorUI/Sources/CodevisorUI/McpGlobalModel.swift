import CodevisorCore
import Foundation
import Observation

/// One MCP server as the fleet list shows it. Managed definitions replicate
/// by NAME — each machine mints its own record id — so the name is the
/// entry's identity here, and the per-machine ids ride along for the calls
/// that need one.
public struct McpFleetEntry: Identifiable, Equatable, Sendable {
  public var name: String
  public var kind: String?
  public var transport: String
  public var authType: String
  public var enabled: Bool
  public var canEdit: Bool
  public var canRemove: Bool
  /// The record id on each machine that has this server.
  public var idByMachine: [String: String]
  /// Whether each machine has this server switched on. Built-ins are never
  /// replicated, so this genuinely differs per machine; a managed server's
  /// entries agree once the fleet has converged.
  public var enabledByMachine: [String: Bool] = [:]
  /// The best-known copy, for the editor sheet and the detail sheet.
  public var representative: ServerMcpServer
  public var id: String { name }

  public var isBuiltIn: Bool { representative.isBuiltIn }

  /// Built-ins are never replicated — `reconcileMcps` publishes only
  /// `kind == "managed"` — so each machine's switch is genuinely its own.
  /// Browser Use and Computer Use make that obvious (a browser, an
  /// extension, TCC grants), and the Codevisor gateway is stored the same
  /// way. A fleet-level toggle over any of them would write to one machine
  /// while implying all of them, so there isn't one.
  public var isMachineScoped: Bool { isBuiltIn }

  /// A machine that can answer calls about this server, preferring the
  /// local one so edits land where the user is.
  public func machineId(preferring preferred: String?) -> String? {
    if let preferred, idByMachine[preferred] != nil { return preferred }
    return idByMachine.keys.sorted().first
  }
}

/// Shared state for the MCP fleet list: every machine's server list merged
/// by name, plus each machine's Browser Use configuration (a genuinely
/// per-machine setting that never syncs).
@MainActor @Observable
public final class McpGlobalModel {
  public private(set) var entries: [McpFleetEntry] = []
  public private(set) var browserByMachine: [String: ServerBrowserUseConfiguration] = [:]
  /// Machines that answered at all, so the list can tell "no servers" from
  /// "nobody could say".
  public private(set) var respondingMachines: Set<String> = []
  public var isLoading = true
  public var actionError: String?

  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  /// Discards answers from a sweep that a newer one has replaced.
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored private var merged: [String: McpFleetEntry] = [:]

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

  public var builtIns: [McpFleetEntry] { entries.filter(\.isBuiltIn) }
  public var managed: [McpFleetEntry] { entries.filter { !$0.isBuiltIn } }

  public func entry(named name: String) -> McpFleetEntry? {
    entries.first { $0.name == name }
  }

  /// The machine rows for one entry, with a built-in's per-machine switch
  /// taken from the machine itself rather than the overlay plane.
  @MainActor
  static func machineRows(
    entry: McpFleetEntry, sync: ConfigSync, machines: [FleetMachineInfo]
  ) -> [McpFleet.MachineRow] {
    McpFleet.rowsRespectingBuiltIns(
      name: entry.name, isMachineScoped: entry.isMachineScoped,
      enabledByMachine: entry.enabledByMachine, sync: sync, machines: machines)
  }

  /// Fans the server list out across every machine and merges by name. A
  /// machine that can't answer is skipped, not fatal.
  /// Asks every machine at once and publishes each answer as it lands. A
  /// sequential sweep made one unreachable machine hold the whole page on
  /// "Loading…" for its full HTTP timeout, hiding the machines that had
  /// already replied — the opposite of what a fleet view is for.
  public func load(in environment: AppEnvironment) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    defer { if generation == loadGeneration { isLoading = false } }
    merged = [:]
    respondingMachines = []
    // Every machine is asked at once and publishes its own answer the moment
    // it lands. Awaiting them in order instead would let one unreachable
    // machine hold the whole page on "Loading…" for its full timeout, hiding
    // the machines that had already replied.
    let probes = environment.machines.allMachines.map { machine in
      let client = environment.machines.client(for: machine.id)
      return Task { @MainActor [weak self] in
        let servers = try? await client.listMcpServers()
        guard let self, generation == self.loadGeneration, let servers else { return }
        self.absorb(servers, from: machine.id)
      }
    }
    for probe in probes { await probe.value }
    guard generation == loadGeneration else { return }
    await loadBrowserConfigurations(in: environment)
  }

  private func absorb(_ servers: [ServerMcpServer], from machineId: String) {
    respondingMachines.insert(machineId)
    for server in servers {
      merge(server, from: machineId, into: &merged)
    }
    publish(merged)
  }

  /// Browser Use's browser choice is stored per machine and never syncs, so
  /// it is fetched only from the machines that actually have the built-in.
  private func loadBrowserConfigurations(in environment: AppEnvironment) async {
    guard let hosts = merged.values.first(where: { $0.kind == "browserUse" })?.idByMachine.keys
    else { return }
    let probes = hosts.map { machineId in
      let client = environment.machines.client(for: machineId)
      return Task { @MainActor [weak self] in
        let configuration = try? await client.browserUseConfiguration()
        guard let self, let configuration else { return }
        self.browserByMachine[machineId] = configuration
      }
    }
    for probe in probes { await probe.value }
  }

  private func publish(_ merged: [String: McpFleetEntry]) {
    entries = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Managed servers replicate by name, so one machine's row completes the
  /// picture another machine started.
  private func merge(
    _ server: ServerMcpServer, from machineId: String, into merged: inout [String: McpFleetEntry]
  ) {
    if var existing = merged[server.name] {
      existing.idByMachine[machineId] = server.id
      existing.enabledByMachine[machineId] = server.enabled
      // A connected copy describes the server better than a machine that
      // never reached it (tool counts, detail text).
      if server.connectionState == "connected",
        existing.representative.connectionState != "connected"
      {
        existing.representative = server
      }
      merged[server.name] = existing
    } else {
      merged[server.name] = McpFleetEntry(
        name: server.name,
        kind: server.kind,
        transport: server.transport,
        authType: server.authType,
        enabled: server.enabled,
        canEdit: server.canEdit != false,
        canRemove: server.canRemove != false,
        idByMachine: [machineId: server.id],
        enabledByMachine: [machineId: server.enabled],
        representative: server)
    }
    // The fleet definition is one value; any machine reporting it off means
    // the definition is off (a machine-local opt-out lives in the overlay
    // plane, not here). Built-ins are exempt: they never replicate, so one
    // machine's switch says nothing about the others.
    if !server.enabled, merged[server.name]?.isMachineScoped == false {
      merged[server.name]?.enabled = false
    }
  }

  /// Switches one machine's copy on or off. The only control a built-in
  /// has, and the way a managed server's fleet definition is re-enabled.
  public func setEnabled(
    _ entry: McpFleetEntry, on machineId: String, enabled: Bool, in environment: AppEnvironment
  ) async {
    guard let serverId = entry.idByMachine[machineId] else {
      actionError = "\(entry.name) isn’t on that machine yet."
      return
    }
    do {
      _ = try await environment.machines.client(for: machineId)
        .setMcpServerEnabled(id: serverId, enabled: enabled)
      actionError = nil
      await load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  /// Flips the fleet definition through a machine that has the server. The
  /// definition replicates by name, so which machine answers doesn't matter
  /// — only that one does.
  public func setFleetEnabled(
    _ entry: McpFleetEntry, enabled: Bool, in environment: AppEnvironment
  ) async {
    guard let machineId = entry.machineId(preferring: CodevisorMachine.local.id) else {
      actionError = "No machine has this server yet."
      return
    }
    await setEnabled(entry, on: machineId, enabled: enabled, in: environment)
  }
}
