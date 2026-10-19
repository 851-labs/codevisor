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
      read: { try pasteboard.read(richContent: $0) },
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

  func receive(_ message: ScreenSharingClipboardSharingMessage) -> ScreenSharingClipboardSharingMessage? {
    guard case .viewer(let sharing, let richContent) = message else { return nil }
    setSharing(sharing)
    guard richContent == true, !transfer.richContent else { return nil }
    transfer.richContent = true
    return .host(richContent: true)
  }

  private func setSharing(_ sharing: Bool) {
    if sharing, !self.sharing { sync.reset(synced: pasteboard.changeCount) }
    self.sharing = sharing
  }

  func poll() {
    guard sharing, !transfer.isBusy, let content = sync.changedContent(richContent: transfer.richContent) else {
      return
    }
    transfer.sendContent(content)
  }

  func tick() { transfer.tick() }
  func cancel(reason: String) { transfer.cancel(reason: reason) }
}
