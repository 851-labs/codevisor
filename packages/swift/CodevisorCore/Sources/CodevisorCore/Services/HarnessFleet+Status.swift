import Foundation

public extension HarnessFleet {
  typealias FleetMachine = FleetMachineInfo

  enum MachineStatus: Equatable, Sendable {
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

  enum SharedSignIn: Equatable, Sendable {
    case notShared
    case pending
    case signedIn(at: Date)
    case unresolved
  }

  struct MachineRow: Identifiable, Equatable, Sendable {
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

  struct HarnessStatus: Equatable, Sendable {
    public var machines: [MachineRow]

    public init(machines: [MachineRow]) {
      self.machines = machines
    }
  }

  nonisolated static let blockedFallbackReason = "Couldn’t sync this harness."

  nonisolated static func machineStatus(state: String, reason: String?) -> MachineStatus {
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

  nonisolated static func machineRows(
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

  static func status(
    harnessId: String, sync: ConfigSync, machines: [FleetMachine], sharedSignIn: SharedSignIn = .notShared
  ) -> HarnessStatus {
    let wantsOn = settings(sync, includingUninstalled: true).first { $0.id == harnessId }?.enabled ?? false
    return HarnessStatus(
      machines: machineRows(
        harnessId: harnessId, readiness: readiness(sync), machines: machines, sharedSignIn: sharedSignIn,
        wantsOn: wantsOn))
  }

  static func fleetMachines(_ machines: MachineController) -> [FleetMachine] {
    FleetMachineInfo.all(machines)
  }
}
