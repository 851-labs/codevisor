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

  var appChallenge: ServerScreenSharingChallenge? { advertisesAppSessions ? challenge : nil }

  var rejectsTheProof: Bool { base.reason == .proofRejected }

  var canShare: Bool { base.version == 1 && ["available", "busy"].contains(base.status) }

  var grant: ServerScreenSharingMediaGrant? {
    base.version == 1 && base.status == "connecting" ? base.media : nil
  }

  var isSharing: Bool { base.version == 1 && ["connecting", "viewing"].contains(base.status) }

  var offersV2: Bool { base.engines?.contains(Self.engine) == true }

  var switchesDisplays: Bool { base.abilities?.contains(ServerScreenSharingReply.displaySwitch) == true }

  var isStillSwitchingDisplay: Bool { base.reason == .displaySwitching }

  var cannotSwitchDisplay: Bool { base.reason == .displayUnavailable }

  var advertisesAppSessions: Bool { base.abilities?.contains(ServerScreenSharingReply.appSessions) == true }

  func isCurrentHost(forTarget hasTarget: Bool) -> Bool {
    base.provider == "vnc" || advertisesAppSessions && (hasTarget || switchesDisplays)
  }

  func targetRefusal() -> ScreenSharingAttemptEnd {
    guard base.reason == nil, !["stopped", "failed"].contains(base.status) else { return end() }

    return .refused(.unclassified(message: base.message))
  }

  func end() -> ScreenSharingAttemptEnd {
    let reason = ScreenSharingFailureReason(
      hostReason: base.reason, holderName: base.holderName, message: base.message)
    if let reason { return .refused(reason) }
    switch base.status {
    case "busy": return .refused(.unclassified(message: base.message))
    case "permission-required": return .refused(.permissionMissing)
    case "stopped": return .dropped(.unclassified(message: base.message))
    default: return .hostFailed(message: base.message)
    }
  }
}
