import Foundation

public struct McpAccountActions: Equatable, Sendable {
  public let serverName: String

  public init(serverName: String) {
    self.serverName = serverName
  }

  public var signInTitle: String { "Sign in with \(serverName)" }

  public var accountTitle: String { "Signed in" }

  public var signInAgainTitle: String { "Sign In Again…" }

  public var signOutTitle: String { "Sign Out" }

  public var signOutPrompt: String { "Sign out of \(serverName)?" }
}
