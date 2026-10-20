import CodevisorCloud
import Foundation

public struct CloudMachineReach: Equatable, Sendable {
  public var online: Bool
  public var hasTunnel: Bool
  public var path: CloudTunnelPath?
  public var dialing: Bool
  public var lastSeen: Date?

  public init(
    online: Bool, hasTunnel: Bool, path: CloudTunnelPath? = nil, dialing: Bool = false, lastSeen: Date? = nil
  ) {
    self.online = online
    self.hasTunnel = hasTunnel
    self.path = path
    self.dialing = dialing
    self.lastSeen = lastSeen
  }
}

extension CloudMachineReach {
  @MainActor
  public init(presence: CloudMachine, pipes: CloudDirectPathController) {
    let reached = pipes.lastReachable[presence.deviceId]
    let hubLastSeen = presence.online ? nil : Self.parse(presence.lastSeenAt)
    self.init(
      online: presence.online,
      hasTunnel: presence.tunnel != nil,
      path: pipes.paths[presence.deviceId],
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
