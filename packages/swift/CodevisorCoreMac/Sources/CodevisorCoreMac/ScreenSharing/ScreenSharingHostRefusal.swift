import CodevisorClient

enum ScreenSharingHostRefusal: Equatable, Sendable {
  case permissionMissing
  case updateNeeded
  case viewerUpdateNeeded(machine: String)
  case noDisplay
  case inUse(by: String?)

  var reply: ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: status, message: message)
    reply.reason = reason
    if case .viewerUpdateNeeded = self { reply.displays = [] }
    if case .inUse(let name) = self { reply.holderName = name }
    return reply
  }

  private var status: String {
    switch self {
    case .permissionMissing: "permission-required"
    case .updateNeeded, .viewerUpdateNeeded, .noDisplay: "unavailable"
    case .inUse: "busy"
    }
  }

  private var reason: ServerScreenSharingReason {
    switch self {
    case .permissionMissing: .permissionMissing
    case .updateNeeded, .viewerUpdateNeeded: .updateNeeded
    case .noDisplay: .noDisplay
    case .inUse: .inUse
    }
  }

  static let permissionMessage =
    "This Mac isn't letting Codevisor record its screen. Check Screen Recording in System Settings › Privacy & Security."

  private var message: String {
    switch self {
    case .permissionMissing: Self.permissionMessage
    case .updateNeeded: "Update Codevisor to use Screen Sharing."
    case .viewerUpdateNeeded(let machine): "Update Codevisor on this device to view \(machine)."
    case .noDisplay: "The selected display is no longer available."
    case .inUse: "This Mac is already sharing with another viewer."
    }
  }
}
