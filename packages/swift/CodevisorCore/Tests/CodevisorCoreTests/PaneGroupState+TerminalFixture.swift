import Foundation
@testable import CodevisorCore

extension PaneGroupState {
  @discardableResult
  mutating func addTerminalPane(sessionId: UUID) -> PaneDescriptorState {
    let paneId = UUID()
    let pane = PaneDescriptorState(
      id: paneId,
      kind: .terminal,
      name: PaneDescriptorState.defaultTerminalName,
      terminalKey: "\(sessionId.uuidString):\(paneId.uuidString)"
    )
    panes.append(pane)
    selectedPaneId = pane.id
    return pane
  }
}
