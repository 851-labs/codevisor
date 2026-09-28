import CodevisorCore
import Foundation

/// How the Machines list shows the connection to one machine: a status dot (or spinner) and a
/// short label saying how it's reached, with the round trip when it's connected.
///
/// "Offline" is from this device's point of view: a machine the hub sees but this device can't
/// reach is offline here. Client reachability and sync results take precedence over cloud
/// presence — an online cloud host doesn't prove this device can use it.
public enum MachineConnectionPresentation: Equatable {
  case thisMac
  /// Dialing it, or probing it for the first time.
  case connecting
  case waiting(ServerWaitingReason)
  case syncing
  case peerToPeer(milliseconds: Int?)
  case relayed(relayURL: String?, milliseconds: Int?)
  case publicIP(address: String, milliseconds: Int?)
  /// Its Codevisor is too old to take tunnel connections.
  case updateNeeded
  case offline(lastSeen: Date?)

  public enum Indicator: Equatable {
    /// A green dot.
    case connected
    /// A spinner.
    case busy
    /// A gray dot.
    case inactive
  }

  /// - Parameters:
  ///   - cloud: for a machine reached through Codevisor Cloud.
  ///   - address: for a machine added by address (`host:port`).
  public init(
    isLocal: Bool = false,
    status: MachineStatus?,
    availability: ServerAvailability?,
    navigationSyncState: NavigationSyncState?,
    cloud: CloudMachineReach? = nil,
    address: String? = nil
  ) {
    let lastSeen = cloud?.lastSeen
    if let cloud, cloud.online, !cloud.hasTunnel, !isLocal {
      self = .updateNeeded
      return
    }
    switch availability {
    case .waiting(.connecting):
      // Automatic reconnects retain Offline until the failure clears.
      if case .stale = navigationSyncState {
        self = .offline(lastSeen: lastSeen)
      } else if status?.isReachable == false {
        self = .offline(lastSeen: lastSeen)
      } else {
        self = .connecting
      }
      return
    case .waiting(let reason):
      self = .waiting(reason)
      return
    case .failed:
      self = .offline(lastSeen: lastSeen)
      return
    default: break
    }
    if let status, !status.isReachable {
      self = .offline(lastSeen: lastSeen)
    } else if case .stale = navigationSyncState {
      self = .offline(lastSeen: lastSeen)
    } else if status?.isReachable == true {
      guard navigationSyncState == .current else {
        self = .syncing
        return
      }
      self = Self.connected(
        isLocal: isLocal, cloud: cloud, address: address, statusMilliseconds: status?.roundTripMilliseconds)
    } else if let cloud {
      // Not probed yet: the tunnel's own state decides.
      if cloud.route != nil || cloud.dialing {
        self = .connecting
      } else {
        self = cloud.online ? .connecting : .offline(lastSeen: lastSeen)
      }
    } else {
      self = .connecting
    }
  }

  private static func connected(
    isLocal: Bool, cloud: CloudMachineReach?, address: String?, statusMilliseconds: Int?
  ) -> MachineConnectionPresentation {
    if isLocal { return .thisMac }
    if let cloud {
      switch cloud.route {
      case .peerToPeer(let milliseconds): return .peerToPeer(milliseconds: milliseconds)
      case .relayed(let url, let milliseconds): return .relayed(relayURL: url, milliseconds: milliseconds)
      // Reachable but the path isn't measured yet (the first refresh is moments away).
      case nil: return .peerToPeer(milliseconds: nil)
      }
    }
    return .publicIP(address: address ?? "", milliseconds: statusMilliseconds)
  }

  public var indicator: Indicator {
    switch self {
    case .thisMac, .peerToPeer, .relayed, .publicIP: .connected
    case .connecting, .waiting, .syncing: .busy
    case .updateNeeded, .offline: .inactive
    }
  }

  public func label(now: Date = Date()) -> String {
    switch self {
    case .thisMac: "This Mac"
    case .connecting, .waiting(.connecting): "Connecting…"
    case .waiting(.starting): "Starting…"
    case .waiting(.updating): "Updating…"
    case .waiting(.restarting): "Restarting…"
    case .syncing: "Syncing…"
    case .peerToPeer(let milliseconds): Self.withRoundTrip("Peer-to-peer", milliseconds)
    case .relayed(_, let milliseconds): Self.withRoundTrip("Relayed", milliseconds)
    case .publicIP(_, let milliseconds): Self.withRoundTrip("Public IP", milliseconds)
    case .updateNeeded: "Update needed"
    case .offline(let lastSeen): lastSeen.map { "Last seen \(Self.relative($0, now: now))" } ?? "Offline"
    }
  }

  /// The tooltip, where the label needs explaining.
  public var help: String? {
    switch self {
    case .peerToPeer: "Direct encrypted connection"
    case .relayed(let url, _):
      "Through the Codevisor relay\(Self.relayPlace(url).map { " in \($0)" } ?? ""); a direct connection wasn't possible"
    case .publicIP(let address, _): address.isEmpty ? nil : "Connected to \(address)"
    case .updateNeeded: "Update Codevisor on this machine to connect"
    default: nil
    }
  }

  private static func withRoundTrip(_ label: String, _ milliseconds: Int?) -> String {
    milliseconds.map { "\(label) · \($0) ms" } ?? label
  }

  private static func relative(_ date: Date, now: Date) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
  }

  /// Our relays are named by their Fly region (`relay-sjc-1.codevisor.dev`).
  static func relayPlace(_ url: String?) -> String? {
    guard let host = url.flatMap({ URL(string: $0)?.host() }) else { return nil }
    let places = ["iad": "Virginia", "sjc": "San Jose", "fra": "Frankfurt", "sin": "Singapore"]
    let region = host.split(separator: ".").first?.split(separator: "-").dropFirst().first.map(String.init)
    return region.flatMap { places[$0] }
  }
}
