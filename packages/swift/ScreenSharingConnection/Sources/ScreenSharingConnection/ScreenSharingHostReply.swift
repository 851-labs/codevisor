import CodevisorClient

public struct ScreenSharingHostReply: Sendable {
  public static let appSessions = "app-sessions"

  public var base: ServerScreenSharingReply
  public var abilities: [String]
  public var reason: String?
  public var holderName: String?
  public var display: ServerScreenSharingDisplay?

  public init(
    _ base: ServerScreenSharingReply, abilities: [String] = [], reason: String? = nil, holderName: String? = nil,
    display: ServerScreenSharingDisplay? = nil
  ) {
    self.base = base
    self.abilities = abilities
    self.reason = reason
    self.holderName = holderName
    self.display = display
  }

  var ownsSessionsByApp: Bool { abilities.contains(Self.appSessions) }

  var canShare: Bool { base.version == 1 && ["available", "busy"].contains(base.status) }

  var grant: ServerScreenSharingMediaGrant? {
    base.version == 1 && base.status == "connecting" ? base.media : nil
  }

  var isSharing: Bool { base.version == 1 && ["connecting", "viewing"].contains(base.status) }

  var offersV2: Bool { base.engines?.contains(ScreenSharingHostRequest.engine) == true }

  var lacksTheDisplay: Bool { reason == nil && base.status == "unavailable" }

  func end(heartbeatToOldHost: Bool = false) -> ScreenSharingAttemptEnd {
    if let reason = ScreenSharingFailureReason(hostCode: reason, holderName: holderName) { return .refused(reason) }
    switch base.status {
    case "busy": return .refused(.inUseOldHost)
    case "permission-required": return .refused(.permissionMissing)
    default: break
    }
    let unclassified = ScreenSharingFailureReason.unclassified(message: base.message)
    if heartbeatToOldHost, base.status == "failed" { return .refused(unclassified) }
    return .dropped(unclassified)
  }
}
