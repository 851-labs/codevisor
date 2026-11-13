public enum LocalNetworkStatus: Equatable, Sendable {
  case checking
  case allowed
  case unavailable
  case blocked(app: Bool, server: Bool)
}
