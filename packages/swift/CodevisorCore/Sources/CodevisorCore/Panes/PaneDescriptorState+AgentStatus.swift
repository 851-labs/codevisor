import Foundation

/// What the program in a terminal says it is doing: reported by the program
/// itself (the Program Status Protocol, OSC 7501), or else read by the server
/// from the title an agent CLI sets, which only shows `working` and `idle`.
public enum TerminalActivity: String, Codable, Sendable {
  case working
  case idle
  /// Finished work nobody has looked at yet.
  case done
  /// Can't continue until the user acts.
  case blocked
  /// Failed and stopped.
  case error
}

/// The attention an agent's pane shows, with the same indicators for a chat
/// and a terminal: its agent is working, finished while nobody was looking,
/// needs a response, or failed.
public enum AgentPaneStatus: Sendable, Equatable {
  case working
  case unread
  case actionRequired
  case error
}

extension PaneDescriptorState {
  /// What the terminal's program reports, as a chat would show it; nil (the
  /// pane's ordinary icon) while it is idle or reports nothing. The server
  /// decides when a state ends, so nothing here clears it.
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
