import ScreenSharing
import Foundation
import Observation

@MainActor
@Observable
public final class ScreenSharingViewerClipboard {
  public private(set) var available = false
  public private(set) var busy = false
  public private(set) var message: String?
  public var sharing = false {
    didSet { if sharing != oldValue { sharingChanged() } }
  }
  @ObservationIgnored private let pasteboard: ScreenSharingPasteboard
  @ObservationIgnored private var transfer: ScreenSharingClipboardTransfer!
  @ObservationIgnored private let sync: ScreenSharingClipboardSync
  @ObservationIgnored private let setHostSharing: (Bool) -> Void
  @ObservationIgnored private let hasKeyboardFocus: () -> Bool
  @ObservationIgnored private var controlling = false
  @ObservationIgnored private var expectedChangeCount: Int?
  @ObservationIgnored private var operation: Operation?
  private enum Operation { case send, get, share, receiveShared }
  private var sharingActive: Bool { sharing && controlling }

  init(
    channel: any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>,
    pasteboard: ScreenSharingPasteboard = .init(),
    setHostSharing: @escaping (Bool) -> Void = { _ in },
    hasKeyboardFocus: @escaping () -> Bool = { false }
  ) {
    self.pasteboard = pasteboard
    self.setHostSharing = setHostSharing
    self.hasKeyboardFocus = hasKeyboardFocus
    let sync = ScreenSharingClipboardSync(pasteboard: pasteboard, synced: nil)
    self.sync = sync
    transfer = ScreenSharingClipboardTransfer(
      send: { [weak channel] in channel?.send($0) ?? false },
      canReceiveUnsolicited: { [weak self] in self?.sharingActive ?? false },
      read: { try pasteboard.read(richContent: $0) },
      write: { [weak self] content in
        guard let self else { return }
        try pasteboard.write(content, expectedChangeCount: self.expectedChangeCount)
        sync.wrote(content)
      })
    transfer.onFinished = { [weak self] error in
      guard let self, let operation = self.operation else { return }
      self.operation = nil
      self.expectedChangeCount = nil
      switch operation {
      case .share: sync.sent(succeeded: error == nil)
      case .receiveShared: break
      case .send, .get:
        self.busy = false
        self.message =
          error ?? (operation == .get ? "Remote clipboard copied to this Mac." : "Clipboard sent to the host.")
      }
    }
    channel.onMessage = { [weak self, weak channel] message in
      guard let self else { return }
      if case .read(let id) = message {
        _ = channel?.send(.result(id: id, error: "The viewer shares its clipboard only as it changes."))
        return
      }
      let idle = !self.transfer.isBusy
      if idle, case .begin = message { self.expectedChangeCount = self.pasteboard.changeCount }
      self.transfer.receive(message)
      if idle {
        if self.transfer.isBusy { self.operation = .receiveShared } else { self.expectedChangeCount = nil }
      }
    }
    channel.onAvailabilityChanged = { [weak self] available in
      self?.available = available
      if !available { self?.transfer.cancel(reason: "The clipboard channel closed.") }
    }
    available = channel.isAvailable
  }

  public func sendLocalClipboard() {
    guard available, !busy else { return }
    guard !transfer.isBusy else {
      message = "The clipboard is busy. Try again."
      return
    }
    do {
      let content = try pasteboard.read(richContent: transfer.richContent)
      busy = true; operation = .send; message = "Sending clipboard…"
      transfer.sendContent(content)
    } catch { message = error.localizedDescription }
  }
  public func getRemoteClipboard() {
    guard available, !busy else { return }
    guard !transfer.isBusy else {
      message = "The clipboard is busy. Try again."
      return
    }
    busy = true; operation = .get; message = "Receiving clipboard…"
    expectedChangeCount = pasteboard.changeCount
    transfer.requestContent()
  }

  func hostAcceptsRichContent() {
    guard !transfer.richContent else { return }
    transfer.richContent = true
    sync.reset(synced: nil)
    poll()
  }

  func setControlling(_ controlling: Bool) {
    guard controlling != self.controlling else { return }
    self.controlling = controlling
    setHostSharing(sharingActive)
    poll()
  }

  func poll() {
    guard sharingActive, available, !transfer.isBusy, hasKeyboardFocus(),
      let content = sync.changedContent(richContent: transfer.richContent)
    else { return }
    operation = .share
    transfer.sendContent(content)
  }

  private func sharingChanged() {
    if sharing { sync.reset(synced: nil) }
    setHostSharing(sharingActive)
    poll()
  }

  func tick() { transfer.tick() }
  func close() { available = false; transfer.cancel(reason: "Clipboard transfer ended with the connection.") }
}
