import SwiftUI
import CodevisorCore

/// Workspace-level adapter for the shared tab strip. Each item owns an entire
/// split tree, but its presentation and interaction match pane tabs exactly.
struct WorkspaceTabBar: View {
  let tabs: [WorkspaceTab]
  let selectedTabId: UUID
  let title: (WorkspaceTab) -> String
  let descriptor: (WorkspaceTab) -> PaneDescriptorState?
  let pluginIconClient: (any CodevisorServerClienting)?
  let pluginIconCacheNamespace: String
  let showsShortcutHints: Bool
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  let onMove: (UUID, UUID) -> Void
  let onRename: (UUID, String?) -> Void
  let onNew: () -> Void

  @State private var renamingTabId: UUID?
  @State private var renameText = ""

  var body: some View {
    PaneTabStrip(
      items: tabItems,
      selectedId: selectedTabId,
      addButtonHelp: "New tab (\(ShortcutCatalog.display(for: .newTab)))",
      addButtonAccessibilityLabel: "New tab",
      onSelect: onSelect,
      onClose: onClose,
      onMove: onMove,
      onAdd: onNew,
      onRename: beginRename
    )
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .bottom) { Divider() }
    .alert(
      "Rename Tab",
      isPresented: Binding(
        get: { renamingTabId != nil },
        set: { if !$0 { renamingTabId = nil } }
      ),
      presenting: renamingTabId
    ) { tabId in
      TextField("Title", text: $renameText)
      Button("Rename") {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        onRename(tabId, trimmed.isEmpty ? nil : trimmed)
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var tabItems: [PaneTabStripItem] {
    tabs.enumerated().map { index, tab in
      let pane = descriptor(tab)
      return PaneTabStripItem(
        id: tab.id,
        name: title(tab),
        kind: pane?.kind ?? .newTab,
        isAgentOwned: pane?.attachOnly ?? false,
        pluginId: pane?.pluginId,
        pluginPaneType: pane?.pluginPaneType,
        pluginIconClient: pluginIconClient,
        pluginIconCacheNamespace: pluginIconCacheNamespace,
        canClose: true,
        shortcutHint: showsShortcutHints && index < 9
          ? ShortcutCatalog.tabSelectionHint(index: index)
          : nil
      )
    }
  }

  private func beginRename(_ tabId: UUID) {
    guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
    renameText = title(tab)
    renamingTabId = tabId
  }
}
