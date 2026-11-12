import Foundation

public enum McpAccountState: Equatable, Sendable {
  case signedIn
  case signedOut
  case settling(status: String)
}
