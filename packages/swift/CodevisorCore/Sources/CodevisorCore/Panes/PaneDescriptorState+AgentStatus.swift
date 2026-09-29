import Foundation

/// What an agent CLI running in a terminal says it is doing, as the server
/// reads it from the title the agent sets.
public enum TerminalActivity: String, Codable, Sendable {
  case working
  case idle
}

/// The attention an agent's pane shows, with the same indicators for a chat
/// and a terminal: its agent is working, or (chats only) it finished while
/// nobody was looking.
public enum AgentPaneStatus: Sendable, Equatable {
  case working
  case unread
}

extension PaneDescriptorState {
  /// `.working` while the terminal's agent runs a turn; nil shows the pane's
  /// ordinary icon.
  public var terminalAgentStatus: AgentPaneStatus? {
    kind == .terminal && terminalActivity == .working ? .working : nil
  }
}
