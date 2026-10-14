import Foundation

public enum TerminalActivity: String, Codable, Sendable {
  case working
  case idle
  case done
  case blocked
  case error
}

public enum AgentPaneStatus: Sendable, Equatable {
  case working
  case unread
  case actionRequired
  case error
}

extension PaneDescriptorState {
  public var terminalAgentStatus: AgentPaneStatus? {
    guard kind == .terminal else { return nil }
    switch terminalActivity {
    case .working: return .working
    case .done: return .unread
    case .blocked: return .actionRequired
    case .error: return .error
    case .idle, nil: return nil
    }
  }
}
