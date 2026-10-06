import Foundation

/// The harness-major read of the desired-vs-reported matrix: for one shared
/// harness, what every machine says about it. The shared toggle is the only
/// control; machines converge on their own, so a row is a status — never a
/// place to install or configure.
public extension HarnessFleet {
  /// Every plane resolves machines identically; harnesses keep the old name.
  typealias FleetMachine = FleetMachineInfo

  /// One harness on one machine, reduced to the single word the row shows.
  enum MachineStatus: Equatable, Sendable {
    case ready
    case installing
    case removing
    case signInRequired
    /// The machine couldn't check its sign-in; the reason says why. Still
    /// offers sign-in, but the failure is what the row explains.
    case signInFailed(reason: String)
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
      case .signInRequired, .signInFailed, .blocked: true
      default: false
      }
    }

    /// The machine checked and found no usable account: nothing failed, so
    /// there is no machine-reported text to show, only what to do about it.
    static let signInRequiredReason =
      "This machine has no signed-in account for this harness. Sign in to use it here."

    /// The shared row presentation every fleet page renders from.
    public var rowStatus: FleetRowStatus {
      switch self {
      case .ready: .ready()
      case .blocked(let reason), .signInFailed(let reason): .attention(label, reason: reason)
      case .signInRequired: .attention(label, reason: Self.signInRequiredReason)
      default: isBusy ? .busy(label) : .quiet(label)
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
    case "signInRequired":
      if let reason, !reason.isEmpty { .signInFailed(reason: reason) } else { .signInRequired }
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
  ///
  /// `wantsOn` is the fleet's current wish. A machine still reporting "off"
  /// while the fleet wants it on hasn't caught up with a flip yet, so it
  /// reads as syncing until it reports ready or a failure.
  nonisolated static func machineRows(
    harnessId: String, readiness: [String: [MachineReadiness]], machines: [FleetMachine],
    sharedSignIn: SharedSignIn = .notShared, wantsOn: Bool = false
  ) -> [MachineRow] {
    machines.map { machine in
      var status: MachineStatus
      if !machine.isReachable {
        status = .unreachable
      } else if let key = machine.syncKey, let row = readiness[key]?.first(where: { $0.harnessId == harnessId }) {
        status = machineStatus(state: row.state, reason: row.reason)
        if status == .off, wantsOn { status = .syncing }
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
