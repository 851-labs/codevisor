import Foundation

extension PaneDescriptorState {
  /// Agent terminals attach to an existing process; user terminals create a shell.
  public var isAgentTerminal: Bool { kind == .terminal && attachOnly }
}

/// Presentation policy shared by native navigation surfaces. Keeping this out
/// of persistence lets a future preference reveal the same running terminals.
public struct PaneNavigationVisibility: Sendable {
  public var hideAgentTerminals: Bool

  public init(hideAgentTerminals: Bool = true) {
    self.hideAgentTerminals = hideAgentTerminals
  }

  public func includes(_ pane: PaneDescriptorState) -> Bool {
    !hideAgentTerminals || !pane.isAgentTerminal
  }
}
