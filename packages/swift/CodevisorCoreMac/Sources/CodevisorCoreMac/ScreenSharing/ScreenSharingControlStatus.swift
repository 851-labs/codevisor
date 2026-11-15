public struct ScreenSharingControlStatus: Equatable, Sendable {
  public var phase = ControlLease.Phase.viewing
  public var message: String?

  public init(phase: ControlLease.Phase = .viewing, message: String? = nil) {
    self.phase = phase
    self.message = message
  }
}
