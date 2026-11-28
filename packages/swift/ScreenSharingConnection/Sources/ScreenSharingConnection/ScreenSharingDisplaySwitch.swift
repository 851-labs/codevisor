public struct ScreenSharingDisplaySwitch: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case switching
    case confirmed
    case unavailable(message: String?)
  }

  public let displayId: String
  public let name: String?
  public let phase: Phase

  public init(displayId: String, name: String? = nil, phase: Phase) {
    self.displayId = displayId
    self.name = name
    self.phase = phase
  }

  public func with(_ phase: Phase) -> Self {
    Self(displayId: displayId, name: name, phase: phase)
  }

  public var failure: String? {
    guard case .unavailable(let message) = phase else { return nil }

    return message ?? "Couldn't switch to \(name ?? "the other display")."
  }
}
