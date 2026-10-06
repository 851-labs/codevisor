import SwiftUI
import CodevisorCore

/// The workspace's top tabs as a horizontal strip above its content. Each
/// item owns an entire split tree.
struct WorkspaceTabBar: View {
  let items: [PaneTabStripItem]
  let selectedTabId: UUID
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  let onMove: (_ id: UUID, _ successorId: UUID?) -> Void
  let onRename: (UUID, String?) -> Void
  let onNew: () -> Void

  @State private var renamingTabId: UUID?
  @State private var renameText = ""

  var body: some View {
    PaneTabStrip(
      items: items,
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

  private func beginRename(_ tabId: UUID) {
    guard let item = items.first(where: { $0.id == tabId }) else { return }
    renameText = item.name
    renamingTabId = tabId
  }
}
