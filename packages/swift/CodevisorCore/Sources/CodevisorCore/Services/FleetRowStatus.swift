import Foundation

/// What a settings list knows about a machine before reading its report.
/// Shared by every fleet plane (harnesses, MCPs, skills, plugins) so the
/// four pages resolve machines the same way.
public struct FleetMachineInfo: Identifiable, Equatable, Sendable {
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

  /// Every machine the client knows, in list order — rows must not jump
  /// while a fleet converges.
  @MainActor
  public static func all(_ machines: MachineController) -> [FleetMachineInfo] {
    machines.allMachines.map { machine in
      FleetMachineInfo(
        id: machine.id,
        name: machine.name,
        syncKey: machines.syncKey(forMachineId: machine.id),
        isReachable: machines.statusByMachineId[machine.id]?.isReachable != false)
    }
  }
}

/// One entry on one machine, reduced to what the row actually renders. Each
/// plane keeps its own state enum (the states genuinely differ: a skill is
/// never "signed out", an MCP is never "waiting to install") and maps it
/// here, so the mark, the caption, and the details popover stay identical
/// across all four pages.
public struct FleetRowStatus: Equatable, Sendable {
  /// How much of the user's attention the row deserves. `quiet` renders no
  /// mark at all — "off" and "unreachable" are facts, not problems.
  public enum Emphasis: Equatable, Sendable {
    case ready
    case busy
    case attention
    case quiet
  }

  public var emphasis: Emphasis
  /// The short phrase the mark's tooltip and VoiceOver use ("Ready").
  public var label: String
  /// The full failure text, when there is one. Its presence is what offers
  /// the row a Details… button.
  public var reason: String?

  public init(emphasis: Emphasis, label: String, reason: String? = nil) {
    self.emphasis = emphasis
    self.label = label
    self.reason = reason
  }

  public var isBusy: Bool { emphasis == .busy }
  public var needsAttention: Bool { emphasis == .attention }

  public static func ready(_ label: String = "Ready") -> FleetRowStatus {
    FleetRowStatus(emphasis: .ready, label: label)
  }

  public static func busy(_ label: String) -> FleetRowStatus {
    FleetRowStatus(emphasis: .busy, label: label)
  }

  public static func attention(_ label: String, reason: String? = nil) -> FleetRowStatus {
    FleetRowStatus(emphasis: .attention, label: label, reason: reason)
  }

  public static func quiet(_ label: String) -> FleetRowStatus {
    FleetRowStatus(emphasis: .quiet, label: label)
  }

  /// The two statuses every plane resolves before it ever reads a report.
  public static let unreachable = FleetRowStatus.quiet("Unreachable")
  public static let syncing = FleetRowStatus.busy("Syncing…")

  nonisolated public static let blockedFallbackReason = "Couldn’t sync this to the machine."
}

public extension FleetRowStatus {
  /// True when a folded single-machine row should render a mark at all.
  /// With one machine there is nothing to compare against, so a check on
  /// every row is just a column of green repeating "fine" — the same noise
  /// a caption saying "available everywhere" would be. Only progress and
  /// problems earn the space. Machine rows in a real fleet still show the
  /// check, because there it distinguishes machines from each other.
  var isWorthFoldingUp: Bool { emphasis != .ready && emphasis != .quiet }
}
