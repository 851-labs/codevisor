import ScreenSharing

@MainActor
final class ScreenSharingHostClipboard {
  private let transfer: ScreenSharingClipboardTransfer
  private let pasteboard: ScreenSharingPasteboard
  private let sync: ScreenSharingClipboardSync
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
      if case .begin = message, sync.isSending { transfer?.cancel() }
      transfer?.receive(message)
    }
    channel.onAvailabilityChanged = { [weak transfer] available in
      if !available { transfer?.cancel(reason: "The clipboard channel closed.") }
    }
  }

  func setSharing(_ sharing: Bool) {
    if sharing, !self.sharing { sync.reset(synced: pasteboard.changeCount) }
    self.sharing = sharing
  }

  func poll() {
    guard sharing, !transfer.isBusy, let text = sync.changedText() else { return }
    transfer.sendText(text)
  }

  func tick() { transfer.tick() }
  func cancel(reason: String) { transfer.cancel(reason: reason) }
}
