import Foundation

public enum PluginSetupStep: Equatable, Sendable {
  case checking
  case install
  case signIn
  case ready
  case unavailable
  case failed
}
