import ScreenSharing
import Foundation
import Observation

@MainActor
@Observable
public final class ScreenSharingViewerClipboard {
  public private(set) var available = false
  public private(set) var busy = false
  public private(set) var message: String?
  @ObservationIgnored private let pasteboard: ScreenSharingPasteboard
  @ObservationIgnored private var transfer: ScreenSharingClipboardTransfer!
  @ObservationIgnored private var expectedChangeCount: Int?
  @ObservationIgnored private var receiving = false

  init(
    channel: any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>,
    pasteboard: ScreenSharingPasteboard = .init()
  ) {
    self.pasteboard = pasteboard
    transfer = ScreenSharingClipboardTransfer(
      send: { [weak channel] in channel?.send($0) ?? false },
      read: { try pasteboard.read() },
      write: { [weak self] text in
        guard let self else { return }
        try pasteboard.write(text, expectedChangeCount: self.expectedChangeCount)
      })
    transfer.onFinished = { [weak self] error in
      guard let self else { return }
      self.busy = false
      self.message =
        error ?? (self.receiving ? "Remote text copied to this Mac’s clipboard." : "Text sent to the host’s clipboard.")
      self.expectedChangeCount = nil
    }
    channel.onMessage = { [weak transfer] in transfer?.receive($0) }
    channel.onAvailabilityChanged = { [weak self] available in
      self?.available = available
      if !available { self?.transfer.cancel(reason: "The clipboard channel closed.") }
    }
    available = channel.isAvailable
  }

  public func sendLocalText() {
    guard available, !busy else { return }
    do {
      let text = try pasteboard.read()
      busy = true; receiving = false; message = "Sending clipboard text…"
      transfer.sendText(text)
    } catch { message = error.localizedDescription }
  }
  public func getRemoteText() {
    guard available, !busy else { return }
    busy = true; receiving = true; message = "Receiving clipboard text…"
    expectedChangeCount = pasteboard.changeCount
    transfer.requestText()
  }
  func tick() { transfer.tick() }
  func close() { available = false; transfer.cancel(reason: "Clipboard transfer ended with the connection.") }
}
