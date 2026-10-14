import CodevisorCloud
import Foundation

public struct CloudMachineReach: Equatable, Sendable {
  public enum Route: Equatable, Sendable {
    case peerToPeer(milliseconds: Int)
    case relayed(relayURL: String?, milliseconds: Int)
  }

  public var online: Bool
  public var hasTunnel: Bool
  public var route: Route?
  public var dialing: Bool
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
