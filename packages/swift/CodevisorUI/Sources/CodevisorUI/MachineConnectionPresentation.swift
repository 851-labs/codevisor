import CodevisorCore
import Foundation

public enum MachineConnectionPresentation: Equatable {
  case thisMac
  case connecting
  case waiting(ServerWaitingReason)
  case syncing
  case peerToPeer(milliseconds: Int?)
  case relayed(relayURL: String?, milliseconds: Int?)
  case updateNeeded
  case offline(lastSeen: Date?)

  public enum Indicator: Equatable {
    case connected
    case busy
    case inactive
  }

  public init(
    isLocal: Bool = false,
    status: MachineStatus?,
    availability: ServerAvailability?,
    navigationSyncState: NavigationSyncState?,
    cloud: CloudMachineReach? = nil
  ) {
    let lastSeen = cloud?.lastSeen
    if let cloud, cloud.online, !cloud.hasTunnel, !isLocal {
      self = .updateNeeded
      return
    }
    if let lifecycle = Self.lifecycle(availability, status: status, sync: navigationSyncState, lastSeen: lastSeen) {
      self = lifecycle
      return
    }
    self =
      Self.reachability(status, sync: navigationSyncState, isLocal: isLocal, cloud: cloud, lastSeen: lastSeen)
      ?? Self.unprobed(cloud, lastSeen: lastSeen)
  }

  private static func lifecycle(
    _ availability: ServerAvailability?, status: MachineStatus?, sync: NavigationSyncState?, lastSeen: Date?
  ) -> Self? {
    switch availability {
    case .waiting(.connecting):
      if case .stale = sync {
        return .offline(lastSeen: lastSeen)
      } else if status?.isReachable == false {
        return .offline(lastSeen: lastSeen)
      } else {
        return .connecting
      }
    case .waiting(let reason):
      return .waiting(reason)
    case .failed:
      return .offline(lastSeen: lastSeen)
    default: return nil
    }
  }

  private static func reachability(
    _ status: MachineStatus?, sync: NavigationSyncState?, isLocal: Bool, cloud: CloudMachineReach?, lastSeen: Date?
  ) -> Self? {
    if let status, !status.isReachable {
      return .offline(lastSeen: lastSeen)
    } else if case .stale = sync {
      return .offline(lastSeen: lastSeen)
    } else if status?.isReachable == true {
      guard sync == .current else { return .syncing }
      return Self.connected(isLocal: isLocal, cloud: cloud)
    }
    return nil
  }

  private static func unprobed(_ cloud: CloudMachineReach?, lastSeen: Date?) -> Self {
    if let cloud {
      if cloud.route != nil || cloud.dialing {
        return .connecting
      } else {
        return cloud.online ? .connecting : .offline(lastSeen: lastSeen)
      }
    } else {
      return .connecting
    }
  }

  private static func connected(isLocal: Bool, cloud: CloudMachineReach?) -> MachineConnectionPresentation {
    if isLocal { return .thisMac }
    switch cloud?.route {
    case .peerToPeer(let milliseconds): return .peerToPeer(milliseconds: milliseconds)
    case .relayed(let url, let milliseconds): return .relayed(relayURL: url, milliseconds: milliseconds)
    case nil: return .peerToPeer(milliseconds: nil)
    }
  }

  public var indicator: Indicator {
    switch self {
    case .thisMac, .peerToPeer, .relayed: .connected
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
    case .updateNeeded: "Update needed"
    case .offline(let lastSeen): lastSeen.map { "Last seen \(Self.relative($0, now: now))" } ?? "Offline"
    }
  }

  public var help: String? {
    switch self {
    case .peerToPeer: "Direct encrypted connection"
    case .relayed(let url, _):
      "Through the Codevisor relay\(Self.relayPlace(url).map { " in \($0)" } ?? ""); a direct connection wasn't possible"
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

  static func relayPlace(_ url: String?) -> String? {
    guard let host = url.flatMap({ URL(string: $0)?.host() }) else { return nil }
    let places = ["iad": "Virginia", "sjc": "San Jose", "fra": "Frankfurt", "sin": "Singapore"]
    let region = host.split(separator: ".").first?.split(separator: "-").dropFirst().first.map(String.init)
    return region.flatMap { places[$0] }
  }
}
