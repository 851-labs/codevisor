import Foundation

@MainActor
public enum HarnessFleet {
  public struct MachineReadiness: Identifiable, Equatable, Sendable {
    public let harnessId: String
    public let state: String
    public let reason: String?
    public let installed: Bool?
    public let version: String?
    public let reportedAt: Date?
    public let name: String?
    public let symbolName: String?
    public let authRequired: Bool?
    public var id: String { harnessId }

    public var majorVersion: Int? {
      version.flatMap { Int($0.drop { $0 == "v" }.prefix { $0.isNumber }) }
    }

    public init(
      harnessId: String, state: String, reason: String?, installed: Bool? = nil, version: String? = nil,
      reportedAt: Date? = nil, name: String? = nil, symbolName: String? = nil, authRequired: Bool? = nil
    ) {
      self.name = name
      self.symbolName = symbolName
      self.authRequired = authRequired
      self.installed = installed
      self.version = version
      self.reportedAt = reportedAt
      self.harnessId = harnessId
      self.state = state
      self.reason = reason
    }
  }

  public static func readiness(_ sync: ConfigSync) -> [String: [MachineReadiness]] {
    _ = sync.revisionsByNamespace["harness-readiness"]
    var result: [String: [MachineReadiness]] = [:]
    for entry in sync.entries(namespace: "harness-readiness") where entry.deleted != true {
      guard case .object(let value) = entry.value,
        case .array(let harnesses) = value["harnesses"] ?? .null
      else { continue }
      result[entry.key] = harnesses.compactMap { harness in
        guard case .object(let fields) = harness,
          case .string(let id) = fields["id"] ?? .null,
          case .string(let state) = fields["state"] ?? .null
        else { return nil }
        let reason: String? =
          if case .string(let text) = fields["reason"] ?? .null { text } else { nil }
        let installed: Bool? = if case .bool(let value) = fields["installed"] { value } else { nil }
        let version: String? = if case .string(let value) = fields["version"] { value } else { nil }
        let name: String? = if case .string(let value) = fields["name"], !value.isEmpty { value } else { nil }
        let symbolName: String? =
          if case .string(let value) = fields["symbolName"], !value.isEmpty { value } else { nil }
        let authRequired: Bool? = if case .bool(let value) = fields["authRequired"] { value } else { nil }
        return MachineReadiness(
          harnessId: id, state: state, reason: reason, installed: installed, version: version,
          reportedAt: entry.timestamp.date, name: name, symbolName: symbolName, authRequired: authRequired)
      }
    }
    return result
  }

  public struct CatalogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let symbolName: String
    public let authRequired: Bool
  }

  public static func catalog(_ sync: ConfigSync) -> [CatalogEntry] {
    var rowsById: [String: [MachineReadiness]] = [:]
    for row in readiness(sync).values.joined() { rowsById[row.harnessId, default: []].append(row) }
    let authored = Dictionary(
      settings(sync, includingUninstalled: true).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return rowsById.map { id, rows in
      let descriptor = HarnessRegistry.descriptor(for: id)
      return CatalogEntry(
        id: id,
        name: rows.lazy.compactMap(\.name).first ?? authored[id]?.name ?? descriptor.displayName,
        symbolName: rows.lazy.compactMap(\.symbolName).first ?? authored[id]?.symbolName ?? descriptor.symbolName,
        authRequired: !rows.contains { $0.authRequired == false })
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public typealias FleetMachine = FleetMachineInfo

  public enum MachineStatus: Equatable, Sendable {
    case ready
    case installing
    case removing
    case signInRequired
    case signInFailed(reason: String)
    case awaitingSignIn
    case syncingSignIn
    case blocked(reason: String)
    case waiting
    case off
    case unreachable
    case syncing

    public var label: String {
      switch self {
      case .ready: "Ready"
      case .installing: "Installing…"
      case .removing: "Removing…"
      case .signInRequired: "Sign in required"
      case .signInFailed: "Couldn’t check sign-in"
      case .awaitingSignIn: "Waiting for sign-in"
      case .syncingSignIn: "Syncing sign-in…"
      case .blocked: "Needs attention"
      case .waiting: "Waiting to install"
      case .off: "Off"
      case .unreachable: "Unreachable"
      case .syncing: "Syncing…"
      }
    }

    public var isBusy: Bool {
      switch self {
      case .installing, .removing, .waiting, .syncing, .syncingSignIn: true
      default: false
      }
    }

    public var needsAttention: Bool {
      switch self {
      case .signInRequired, .signInFailed, .blocked: true
      default: false
      }
    }

    static let signInRequiredReason =
      "This machine has no signed-in account for this harness. Sign in to use it here."

    public var rowStatus: FleetRowStatus {
      switch self {
      case .ready: .ready()
      case .blocked(let reason), .signInFailed(let reason): .attention(label, reason: reason)
      case .signInRequired: .attention(label, reason: Self.signInRequiredReason)
      default: isBusy ? .busy(label) : .quiet(label)
      }
    }
  }

  public enum SharedSignIn: Equatable, Sendable {
    case notShared
    case pending
    case signedIn(at: Date)
    case unresolved
  }

  public struct MachineRow: Identifiable, Equatable, Sendable {
    public var machineId: String
    public var name: String
    public var status: MachineStatus
    public var id: String { machineId }

    public init(machineId: String, name: String, status: MachineStatus) {
      self.machineId = machineId
      self.name = name
      self.status = status
    }
  }

  public struct HarnessStatus: Equatable, Sendable {
    public var machines: [MachineRow]

    public init(machines: [MachineRow]) {
      self.machines = machines
    }
  }

  nonisolated public static let blockedFallbackReason = "Couldn’t sync this harness."

  nonisolated public static func machineStatus(state: String, reason: String?) -> MachineStatus {
    switch state {
    case "ready": .ready
    case "installing": .installing
    case "uninstalling": .removing
    case "signInRequired":
      if let reason, !reason.isEmpty { .signInFailed(reason: reason) } else { .signInRequired }
    case "blocked": .blocked(reason: reason ?? blockedFallbackReason)
    case "notInstalled": .waiting
    case "disabled": .off
    default: .syncing
    }
  }

  nonisolated public static func machineRows(
    harnessId: String, readiness: [String: [MachineReadiness]], machines: [FleetMachine],
    sharedSignIn: SharedSignIn = .notShared, wantsOn: Bool = false
  ) -> [MachineRow] {
    machines.map { machine in
      var status: MachineStatus
      var reportedAt: Date?
      if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey, let row = readiness[key]?.first(where: { $0.harnessId == harnessId }) {
        status = machineStatus(state: row.state, reason: row.reason)
        reportedAt = row.reportedAt
        if status == .off, wantsOn { status = .syncing }
      } else {
        status = .syncing
      }
      if status == .signInRequired {
        switch sharedSignIn {
        case .pending: status = .awaitingSignIn
        case .signedIn(let signedInAt) where (reportedAt ?? .distantPast) < signedInAt:
          status = .syncingSignIn
        case .signedIn, .notShared, .unresolved: break
        }
      }
      return MachineRow(machineId: machine.id, name: machine.name, status: status)
    }
  }

  public static func status(
    harnessId: String, sync: ConfigSync, machines: [FleetMachine], sharedSignIn: SharedSignIn = .notShared
  ) -> HarnessStatus {
    let wantsOn = settings(sync, includingUninstalled: true).first { $0.id == harnessId }?.enabled ?? false
    return HarnessStatus(
      machines: machineRows(
        harnessId: harnessId, readiness: readiness(sync), machines: machines, sharedSignIn: sharedSignIn,
        wantsOn: wantsOn))
  }

  public static func fleetMachines(_ machines: MachineController) -> [FleetMachine] {
    FleetMachineInfo.all(machines)
  }

  public struct SharedHost: Equatable, Sendable {
    public var machineId: String
    public var harness: ServerHarness

    public init(machineId: String, harness: ServerHarness) {
      self.machineId = machineId
      self.harness = harness
    }
  }

  nonisolated public static func sharedHostCandidates(
    harnessId: String, machines: [FleetMachine], readiness: [String: [MachineReadiness]], preferred: String?
  ) -> [String] {
    func report(_ machine: FleetMachine) -> MachineReadiness? {
      machine.syncKey.flatMap { readiness[$0]?.first { $0.harnessId == harnessId } }
    }
    func installed(_ row: MachineReadiness) -> Bool {
      row.installed ?? !["notInstalled", "disabled"].contains(row.state)
    }
    let reachable = machines.filter { machine in
      machine.isReachable && report(machine).map(installed) != false
    }
    let rank = { (machine: FleetMachine) -> Int in
      if machine.id == preferred { return 0 }
      if machine.isLocal { return 1 }
      return report(machine) == nil ? 3 : 2
    }
    return reachable.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element.id)
  }

  public static func findSharedHost(
    harnessId: String, preferred: String? = nil, environment: AppEnvironment
  ) async -> SharedHost? {
    let candidates = sharedHostCandidates(
      harnessId: harnessId, machines: fleetMachines(environment.machines),
      readiness: readiness(environment.configSync), preferred: preferred)
    guard !candidates.isEmpty else { return nil }
    return await withTaskGroup(of: (Int, ServerHarness?).self) { group in
      for (index, machineId) in candidates.enumerated() {
        let client = environment.machines.client(for: machineId)
        group.addTask {
          let harness = try? await client.listHarnesses().first { $0.id == harnessId }
          return (index, harness?.isReady == true ? harness : nil)
        }
      }
      var best: (Int, ServerHarness)?
      var pending = Set(candidates.indices)
      for await (index, harness) in group {
        pending.remove(index)
        if let harness, best == nil || index < best!.0 { best = (index, harness) }
        if let best, pending.allSatisfy({ $0 > best.0 }) {
          group.cancelAll()
          return SharedHost(machineId: candidates[best.0], harness: best.1)
        }
      }
      return best.map { SharedHost(machineId: candidates[$0.0], harness: $0.1) }
    }
  }

  public struct Setting: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var enabled: Bool
    public var installed: Bool
    public init(id: String, name: String, symbolName: String, enabled: Bool, installed: Bool) {
      self.id = id
      self.name = name
      self.symbolName = symbolName
      self.enabled = enabled
      self.installed = installed
    }
  }

  public static func settings(_ sync: ConfigSync, includingUninstalled: Bool = false) -> [Setting] {
    _ = sync.revisionsByNamespace["harnesses"]
    return sync.entries(namespace: "harnesses").compactMap { entry in
      guard entry.deleted != true, !entry.key.hasPrefix("custom:"),
        case .object(let fields) = entry.value,
        case .bool(let enabled) = fields["enabled"],
        case .bool(let installed) = fields["installed"],
        installed || (includingUninstalled && fields["uninstall"] == .bool(true))
      else { return nil }
      let descriptor = HarnessRegistry.descriptor(for: entry.key)
      let name: String =
        if case .string(let name) = fields["name"], !name.isEmpty { name } else { descriptor.displayName }
      let symbol: String =
        if case .string(let symbol) = fields["symbolName"], !symbol.isEmpty { symbol } else { descriptor.symbolName }
      return Setting(id: entry.key, name: name, symbolName: symbol, enabled: enabled, installed: installed)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  @discardableResult
  public static func seed(from harnesses: [ServerHarness], in sync: ConfigSync) -> [String] {
    let authored = Set(settings(sync, includingUninstalled: true).map(\.id))
    var added: [String] = []
    for harness in harnesses where harness.isReady && harness.isDesiredEnabled {
      guard !authored.contains(harness.id) else { continue }
      set(
        Setting(
          id: harness.id, name: harness.name, symbolName: harness.symbolName,
          enabled: true, installed: true),
        in: sync)
      added.append(harness.id)
    }
    return added
  }

  public static func set(_ setting: Setting, in sync: ConfigSync) {
    sync.set(
      namespace: "harnesses", key: setting.id,
      value: .object([
        "name": .string(setting.name), "symbolName": .string(setting.symbolName),
        "enabled": .bool(setting.enabled), "installed": .bool(setting.installed),
        "uninstall": .bool(!setting.installed),
      ]))
  }
}
