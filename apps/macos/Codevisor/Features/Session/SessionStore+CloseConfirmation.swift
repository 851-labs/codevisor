import AppKit
import CodevisorCore

// MARK: - Close confirmation

extension SessionStore {
  /// Runs `close` right away unless it would close a chat whose agent is
  /// still working. In that case it asks first, the way ⌘Q does, and runs
  /// `close` only if the user confirms.
  ///
  /// "Working" is the sidebar spinner's test (`isInProgress`): mid-turn,
  /// running setup, or waiting on its own background work. Closing an idle
  /// chat stays instant.
  func confirmClosingWorkingChats(
    _ panes: [PaneDescriptorState],
    serverId: String,
    then close: @escaping @MainActor () -> Void
  ) {
    guard environment.settings.confirmBeforeClosingWorkingChat,
      containsWorkingChat(panes, serverId: serverId)
    else {
      close()
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
      close()
    }
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible else {
      finish(alert.runModal())
      return
    }
    alert.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated { finish(response) }
    }
  }

  private func containsWorkingChat(_ panes: [PaneDescriptorState], serverId: String) -> Bool {
    panes.contains { pane in
      guard pane.kind == .chat, let chatId = pane.chatSessionId,
        let chat = environment.projectList.session(chatId, serverId: serverId)
      else { return false }
      return isInProgress(chat)
    }
  }

  private static func makeCloseWorkingChatAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Are you sure you want to close this chat?"
    alert.informativeText = "The agent is still working."
    alert.alertStyle = .warning
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Do not ask me again"
    // First button is the default (Return); "Cancel" also binds Escape.
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    return alert
  }
}
