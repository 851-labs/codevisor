import Foundation

public enum CloudSignInProvider: String, CaseIterable, Sendable {
  case github
  case apple
  case email = "credential"

  public var displayName: String {
    switch self {
    case .github: "GitHub"
    case .apple: "Apple"
    case .email: "Email and Password"
    }
  }
}
