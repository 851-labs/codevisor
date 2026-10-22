public enum CloudAccountState: Equatable, Sendable {
  case signedOut
  case validating
  case signedIn(userEmail: String?)

  public var isSignedIn: Bool {
    if case .signedIn = self { return true }
    return false
  }

  var userEmail: String? {
    guard case let .signedIn(email) = self else { return nil }
    return email
  }
}
