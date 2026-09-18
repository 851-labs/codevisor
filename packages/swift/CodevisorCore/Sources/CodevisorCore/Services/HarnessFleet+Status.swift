import Foundation

/// The harness-major read of the desired-vs-reported matrix: for one shared
/// harness, what every machine says about it. The shared toggle is the only
/// control; machines converge on their own, so a row is a status — never a
/// place to install or configure.
public extension HarnessFleet {
  /// What the list knows about a machine before reading its report.
  struct FleetMachine: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The key the machine's server writes its readiness under; nil until probed.
    public var syncKey: String?
    public var isReachable: Bool

    public init(id: String, name: String, syncKey: String?, isReachable: Bool) {
      self.id = id
      self.name = name
      self.syncKey = syncKey
      self.isReachable = isReachable
    }
  }

  /// One harness on one machine, reduced to the single word the row shows.
  enum MachineStatus: Equatable, Sendable {
    case ready
    case installing
    case removing
    case signInRequired
    /// The harness syncs one fleet-wide sign-in that hasn't happened yet;
    /// this machine can't sign in on its own.
    case awaitingSignIn
    /// The fleet has signed in; this machine hasn't picked the account up yet.
    case syncingSignIn
    case blocked(reason: String)
    /// Reported as not installed; the machine's next sync pass installs it.
    case waiting
    case off
    case unreachable
    /// No report yet: the machine hasn't been probed, or hasn't learned this harness.
    case syncing

    public var label: String {
      switch self {
      case .ready: "Ready"
      case .installing: "Installing…"
      case .removing: "Removing…"
      case .signInRequired: "Sign in required"
      case .awaitingSignIn: "Waiting for sign-in"
      case .syncingSignIn: "Syncing sign-in…"
      case .blocked: "Needs attention"
      case .waiting: "Waiting to install"
      case .off: "Off"
      case .unreachable: "Unreachable"
      case .syncing: "Syncing…"
      }
    }

    /// The machine hasn't caught up with the fleet's desired state yet.
    public var isBusy: Bool {
      switch self {
      case .installing, .removing, .waiting, .syncing, .syncingSignIn: true
      default: false
      }
    }

    /// The user has to do something: sign in, or look at a failure.
    public var needsAttention: Bool {
      switch self {
      case .signInRequired, .blocked: true
      default: false
      }
    }
  }

  /// How a harness's sign-in relates to the fleet, as far as the client knows.
  enum SharedSignIn: Equatable, Sendable {
    /// Each machine signs in on its own.
    case notShared
    /// One fleet sign-in, not done yet: the harness row is asking for it.
    case pending
    /// One fleet sign-in landed recently; machines pick it up on their own.
    case signedIn
    /// One fleet sign-in, but the client can't say this machine is catching
    /// up: no account is known, or one has been there long enough that a
    /// machine still asking for it is stuck.
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

  /// The one mapping from a server's reported state string.
  nonisolated static func machineStatus(state: String, reason: String?) -> MachineStatus {
    switch state {
    case "ready": .ready
    case "installing": .installing
    case "uninstalling": .removing
    case "signInRequired": .signInRequired
    case "blocked": .blocked(reason: reason ?? blockedFallbackReason)
    case "notInstalled": .waiting
    case "disabled": .off
    default: .syncing
    }
  }

  /// Machines keep their list order regardless of state, so rows don't
  /// jump while a fleet converges.
  /// A machine's "sign in required" means different things depending on
  /// where the account lives: waiting on the user (quiet, the harness row
  /// asks), catching up with an account that exists (busy), or — when the
  /// client can't tell — something to act on from the machine's row.
  nonisolated static func machineRows(
    harnessId: String, readiness: [String: [MachineReadiness]], machines: [FleetMachine],
    sharedSignIn: SharedSignIn = .notShared
  ) -> [MachineRow] {
    machines.map { machine in
      var status: MachineStatus
      if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey, let row = readiness[key]?.first(where: { $0.harnessId == harnessId }) {
        status = machineStatus(state: row.state, reason: row.reason)
      } else {
        status = .syncing
      }
      if status == .signInRequired {
        switch sharedSignIn {
        case .pending: status = .awaitingSignIn
        case .signedIn: status = .syncingSignIn
        case .notShared, .unresolved: break
        }
      }
      return MachineRow(machineId: machine.id, name: machine.name, status: status)
    }
  }

  static func status(
    harnessId: String, sync: ConfigSync, machines: [FleetMachine], sharedSignIn: SharedSignIn = .notShared
  ) -> HarnessStatus {
    HarnessStatus(
      machines: machineRows(
        harnessId: harnessId, readiness: readiness(sync), machines: machines, sharedSignIn: sharedSignIn))
  }

  static func fleetMachines(_ machines: MachineController) -> [FleetMachine] {
    machines.allMachines.map { machine in
      FleetMachine(
        id: machine.id,
        name: machine.name,
        syncKey: machines.syncKey(forMachineId: machine.id),
        isReachable: machines.statusByMachineId[machine.id]?.isReachable != false)
    }
  }
}
