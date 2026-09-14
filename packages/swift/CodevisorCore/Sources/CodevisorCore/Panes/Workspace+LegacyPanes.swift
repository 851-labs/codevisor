import Foundation

extension Workspace {
  private enum LegacyCodingKeys: String, CodingKey {
    case bottomGroup
  }

  mutating func importLegacyPanes(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
    if let legacy = try container.decodeIfPresent(PaneGroupState.self, forKey: .bottomGroup) {
      importLegacyPanes(legacy.panes)
    }
  }

  /// Imports panes from retired layouts without changing the current selection
  /// or the identities used to attach to running terminals. Deterministic tab
  /// and leaf IDs keep decoding stable before the migrated layout is saved.
  mutating func importLegacyPanes(_ panes: [PaneDescriptorState]) {
    var ids = Set(allPanes.map(\.id))
    var terminalKeys = Set(allPanes.filter { $0.kind == .terminal }.map(\.terminalKey))
    for pane in panes {
      guard ids.insert(pane.id).inserted else { continue }
      if pane.kind == .terminal, !terminalKeys.insert(pane.terminalKey).inserted { continue }
      let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id)
      centerTabs.append(WorkspaceTab(id: pane.id, root: .leaf(state, id: pane.id)))
    }
  }

}
