import CodevisorCloud
import Foundation

/// What this device knows about reaching one cloud machine over the tunnel: the input to the
/// Machines list's connection label.
public struct CloudMachineReach: Equatable, Sendable {
  public enum Route: Equatable, Sendable {
    case peerToPeer(milliseconds: Int)
    /// Through one of our relays (`relayURL`), because a direct path wasn't possible.
    case relayed(relayURL: String?, milliseconds: Int)
  }

  /// The hub sees the machine connected.
  public var online: Bool
  /// The machine's server can take tunnel connections (false: it predates the tunnel).
  public var hasTunnel: Bool
  /// The live pipe's path; nil while there is no pipe.
  public var route: Route?
  public var dialing: Bool
  /// When this device could last reach it, or when the hub last saw it.
  public var lastSeen: Date?

  public init(online: Bool, hasTunnel: Bool, route: Route? = nil, dialing: Bool = false, lastSeen: Date? = nil) {
    self.online = online
    self.hasTunnel = hasTunnel
    self.route = route
    self.dialing = dialing
    self.lastSeen = lastSeen
  }
}

extension CloudMachineReach {
  @MainActor
  public init(presence: CloudMachine, pipes: CloudDirectPathController) {
    let path = pipes.paths[presence.deviceId]
    let reached = pipes.lastReachable[presence.deviceId]
    // An online machine's presence timestamp is when it connected, not when it was last seen.
    let hubLastSeen = presence.online ? nil : Self.parse(presence.lastSeenAt)
    self.init(
      online: presence.online,
      hasTunnel: presence.tunnel != nil,
      route: path.map {
        $0.isRelayed
          ? .relayed(relayURL: $0.relayURL, milliseconds: $0.roundTripMilliseconds)
          : .peerToPeer(milliseconds: $0.roundTripMilliseconds)
      },
      dialing: pipes.dialing.contains(presence.deviceId),
      lastSeen: [reached, hubLastSeen].compactMap { $0 }.max()
    )
  }

  static func parse(_ timestamp: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: timestamp) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: timestamp)
  }
}
