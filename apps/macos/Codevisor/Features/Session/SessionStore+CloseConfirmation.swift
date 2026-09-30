import AppKit
import CodevisorCore

// MARK: - Close confirmation

extension SessionStore {
  /// Runs `close` right away unless it would close a chat whose agent is
  /// still working. In that case it asks first, the way ⌘Q does. Confirming
  /// stops those agents' turns (like pressing Stop) and then runs `close`;
  /// closing a pane alone would leave the agent running with no tab.
  ///
  /// "Working" is the sidebar spinner's test (`isInProgress`): mid-turn,
  /// running setup, or waiting on its own background work. Closing an idle
  /// chat stays instant.
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
    // Repeated ⌘W while the sheet is up must not stack alerts or close
    // anything behind it.
    guard !isConfirmingChatClose else { return }
    isConfirmingChatClose = true
    let alert = Self.makeCloseWorkingChatAlert()
    let settings = environment.settings
    let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
      self?.isConfirmingChatClose = false
      guard response == .alertFirstButtonReturn else { return }
      // Record "Do not ask me again" only on an actual close, so a ticked
      // box on a cancelled alert doesn't silently turn the guard off.
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

  /// Closes immediately, then cancels each chat's in-flight turn. A cached
  /// controller cancels through its model so its own state settles; a chat
  /// with no controller here (working on another device's behalf) is
  /// cancelled directly on its machine.
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
    // First button is the default (Return); "Cancel" also binds Escape.
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    return alert
  }
}
