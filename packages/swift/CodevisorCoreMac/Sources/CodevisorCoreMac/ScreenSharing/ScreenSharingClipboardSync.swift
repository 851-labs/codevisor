import ScreenSharing

@MainActor
final class ScreenSharingClipboardSync {
  private let pasteboard: ScreenSharingPasteboard
  private var synced: Int?
  private var sending: (count: Int, text: String)?
  private var shared: String?
  var isSending: Bool { sending != nil }

  init(pasteboard: ScreenSharingPasteboard, synced: Int?) {
    self.pasteboard = pasteboard
    self.synced = synced
  }

  func reset(synced: Int?) {
    self.synced = synced
    sending = nil
    shared = nil
  }

  func changedText() -> String? {
    let count = pasteboard.changeCount
    guard sending == nil, count != synced else { return nil }
    guard !pasteboard.isPrivate, let text = try? pasteboard.read(), text != shared else {
      synced = count
      return nil
    }
    sending = (count, text)
    return text
  }

  func sent(succeeded: Bool) {
    if let sending {
      synced = sending.count
      if succeeded { shared = sending.text }
    }
    sending = nil
  }

  func wrote(_ text: String) {
    synced = pasteboard.changeCount
    shared = text
  }
}
