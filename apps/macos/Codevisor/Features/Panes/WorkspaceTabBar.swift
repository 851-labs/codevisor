import SwiftUI
import CodevisorCore
import CodevisorUI

struct WorkspaceTabBar: View {
  let items: [PaneTabStripItem]
  let selectedTabId: UUID
  let onSelect: (UUID) -> Void
  var onClose: ((UUID) -> Void)? = nil
  var onMove: ((_ id: UUID, _ successorId: UUID?) -> Void)? = nil
  var onRename: ((UUID, String?) -> Void)? = nil
  var onKeep: ((UUID) -> Void)? = nil
  var onNew: (() -> Void)? = nil

  @State private var renamingTabId: UUID?
  @State private var renameText = ""

  var body: some View {
    PaneTabStrip(
      items: items,
      selectedId: selectedTabId,
      addButtonHelp: "New tab (\(ShortcutCatalog.display(for: .newTab)))",
      addButtonAccessibilityLabel: "New tab",
      onSelect: onSelect,
      onClose: { onClose?($0) },
      onMove: onMove,
      onAdd: onNew,
      onRename: onRename.map { _ in beginRename },
      onKeep: onKeep
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
        onRename?(tabId, trimmed.isEmpty ? nil : trimmed)
      }
      Button("Cancel", role: .cancel) {}
    }
    .focusesAlertTextField(when: renamingTabId != nil)
  }

  private func beginRename(_ tabId: UUID) {
    guard let item = items.first(where: { $0.id == tabId }) else { return }
    renameText = item.name
    renamingTabId = tabId
  }
}

extension PaneTabIcon {
  @MainActor
  static func workspaceTab(
    _ descriptor: PaneDescriptorState?,
    title: String,
    serverId: String,
    environment: AppEnvironment,
    store: SessionStore
  ) -> PaneTabIcon {
    let chatSession = descriptor.flatMap { pane -> ChatSession? in
      guard pane.kind == .chat, let id = pane.chatSessionId else { return nil }
      return environment.projectList.session(id, serverId: serverId)
    }
    let subagentHarnessId = descriptor.flatMap { pane -> String? in
      guard pane.kind == .subagent, let ownerId = pane.ownerChatSessionId else { return nil }
      return environment.projectList.session(ownerId, serverId: serverId)?.harnessId
    }
    return PaneTabIcon(
      kind: descriptor?.kind ?? .newTab,
      browserFavicon: descriptor.flatMap {
        $0.kind == .browser ? store.localBrowserModel(paneId: $0.id)?.favicon : nil
      },
      browserFaviconReference: descriptor?.browserFavicon,
      browserFaviconClient: environment.machines.client(for: serverId),
      pluginId: descriptor?.pluginId,
      pluginIconClient: environment.machines.client(for: serverId),
      pluginIconCacheNamespace: serverId,
      chatSession: chatSession,
      terminalStatus: descriptor?.terminalAgentStatus,
      subagentHarnessId: subagentHarnessId,
      documentPath: title,
      store: store
    )
  }
}
