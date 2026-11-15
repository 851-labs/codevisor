public struct ScreenSharingDisplaySwitch: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case switching
    case confirmed
    case unavailable(message: String?)
  }

  public let displayId: String
  public let phase: Phase

  public init(displayId: String, phase: Phase) {
    self.displayId = displayId
    self.phase = phase
  }
}
