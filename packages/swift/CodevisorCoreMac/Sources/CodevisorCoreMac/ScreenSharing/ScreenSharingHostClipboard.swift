import ScreenSharing

/// The host's clipboard for one session: it answers the viewer's Send and Get, and while the
/// viewer shares the clipboard, sends each new copy made here.
@MainActor
final class ScreenSharingHostClipboard {
  private let transfer: ScreenSharingClipboardTransfer
  private let pasteboard: ScreenSharingPasteboard
  private let sync: ScreenSharingClipboardSync
  /// The viewer wants this Mac's copies.
  private(set) var sharing = false

  init(
    channel: any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>,
    pasteboard: ScreenSharingPasteboard = .init(),
    canReceiveUnsolicited: @escaping () -> Bool
  ) {
    self.pasteboard = pasteboard
    let sync = ScreenSharingClipboardSync(pasteboard: pasteboard, synced: pasteboard.changeCount)
    self.sync = sync
    let transfer = ScreenSharingClipboardTransfer(
      send: { [weak channel] in channel?.send($0) ?? false },
      canReceiveUnsolicited: canReceiveUnsolicited,
      read: { try pasteboard.read() },
      write: {
        try pasteboard.write($0)
        sync.wrote($0)
      })
    transfer.onFinished = { error in sync.sent(succeeded: error == nil) }
    self.transfer = transfer
    channel.onMessage = { [weak transfer] message in
      // Both Macs copied at once: the viewer's copy wins, since the user is working there.
      if case .begin = message, sync.isSending { transfer?.cancel() }
      transfer?.receive(message)
    }
    channel.onAvailabilityChanged = { [weak transfer] available in
      if !available { transfer?.cancel(reason: "The clipboard channel closed.") }
    }
  }

  /// Shared clipboard on or off. Turned on, only copies made from now on are sent, so a copy
  /// here older than the viewer's never replaces it.
  func setSharing(_ sharing: Bool) {
    if sharing, !self.sharing { sync.reset(synced: pasteboard.changeCount) }
    self.sharing = sharing
  }

  /// Sends a new copy made here, while sharing. The caller checks the viewer holds control.
  func poll() {
    guard sharing, !transfer.isBusy, let text = sync.changedText() else { return }
    transfer.sendText(text)
  }

  func tick() { transfer.tick() }
  func cancel(reason: String) { transfer.cancel(reason: reason) }
}
