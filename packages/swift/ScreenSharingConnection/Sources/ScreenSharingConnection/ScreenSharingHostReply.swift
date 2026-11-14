import CodevisorClient

struct ScreenSharingHostReply {
  static let engine = "v2"

  let base: ServerScreenSharingReply

  init(_ base: ServerScreenSharingReply) {
    self.base = base
  }

  var challenge: ServerScreenSharingChallenge? {
    guard let challenge = base.challenge, ServerScreenSharingProof.isKey(challenge.hostKey),
      ServerScreenSharingProof.isKey(challenge.nonce)
    else { return nil }

    return challenge
  }

  var appChallenge: ServerScreenSharingChallenge? {
    base.abilities?.contains(ServerScreenSharingReply.appSessions) == true ? challenge : nil
  }

  var ownsSessionsByApp: Bool { appChallenge != nil }

  var rejectsTheProof: Bool { base.reason == .proofRejected }

  var canShare: Bool { base.version == 1 && ["available", "busy"].contains(base.status) }

  var grant: ServerScreenSharingMediaGrant? {
    base.version == 1 && base.status == "connecting" ? base.media : nil
  }

  var isSharing: Bool { base.version == 1 && ["connecting", "viewing"].contains(base.status) }

  var offersV2: Bool { base.engines?.contains(Self.engine) == true }

  var lacksTheDisplay: Bool { base.reason == nil && base.status == "unavailable" }

  func end(heartbeatToOldHost: Bool = false) -> ScreenSharingAttemptEnd {
    if let reason = ScreenSharingFailureReason(hostReason: base.reason, holderName: base.holderName) {
      return .refused(reason)
    }
    switch base.status {
    case "busy": return .refused(.inUseOldHost)
    case "permission-required": return .refused(.permissionMissing)
    case "stopped": return .dropped(.unclassified(message: base.message))
    default: break
    }
    if heartbeatToOldHost, base.status == "failed" { return .endedByHost(message: base.message) }
    return .hostFailed(message: base.message)
  }
}
