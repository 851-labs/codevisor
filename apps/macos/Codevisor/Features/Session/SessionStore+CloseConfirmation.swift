import AppKit
import CodevisorCore

extension SessionStore {
  func confirmClosingWorkingChats(
    _ panes: [PaneDescriptorState],
    serverId: String,
    then close: @escaping @MainActor () -> Void
  ) {
    let working = workingChats(in: panes, serverId: serverId)
    guard !working.isEmpty else {
      close()
      return
    }
    guard environment.settings.confirmBeforeClosingWorkingChat else {
      stopAndClose(working, then: close)
      return
    }
    guard !isConfirmingChatClose else { return }
    isConfirmingChatClose = true
    let alert = Self.makeCloseWorkingChatAlert()
    let settings = environment.settings
    let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
      self?.isConfirmingChatClose = false
      guard response == .alertFirstButtonReturn else { return }
      if alert.suppressionButton?.state == .on {
        settings.setConfirmBeforeClosingWorkingChat(false)
      }
      self?.stopAndClose(working, then: close)
    }
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible else {
      finish(alert.runModal())
      return
    }
    alert.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated { finish(response) }
    }
  }

  private func workingChats(in panes: [PaneDescriptorState], serverId: String) -> [ChatSession] {
    panes.compactMap { pane in
      guard pane.kind == .chat, let chatId = pane.chatSessionId,
        let chat = environment.projectList.session(chatId, serverId: serverId),
        isInProgress(chat)
      else { return nil }
      return chat
    }
  }

  private func stopAndClose(_ chats: [ChatSession], then close: @MainActor () -> Void) {
    close()
    for chat in chats {
      let controller = controllers[SessionKey(chat)]
      let client = environment.machines.client(for: chat.serverId)
      Task {
        if let controller, controller.isSending {
          await controller.stop()
        } else {
          try? await client.cancelSession(id: chat.id)
        }
      }
    }
  }

  private static func makeCloseWorkingChatAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Are you sure you want to close this chat?"
    alert.informativeText = "The agent is still working. Closing this chat will stop it."
    alert.alertStyle = .warning
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Do not ask me again"
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    return alert
  }
}
