import ScreenSharing

@MainActor
final class ScreenSharingClipboardSync {
  private let pasteboard: ScreenSharingPasteboard
  private var synced: Int?
  private var sending: (count: Int, content: ScreenSharingClipboardContent)?
  private var shared: ScreenSharingClipboardContent?
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

  func changedContent(richContent: Bool) -> ScreenSharingClipboardContent? {
    let count = pasteboard.changeCount
    guard sending == nil, count != synced else { return nil }
    guard !pasteboard.isPrivate, let content = try? pasteboard.read(richContent: richContent), content != shared
    else {
      synced = count
      return nil
    }
    sending = (count, content)
    return content
  }

  func sent(succeeded: Bool) {
    if let sending {
      synced = sending.count
      if succeeded { shared = sending.content }
    }
    sending = nil
  }

  func wrote(_ content: ScreenSharingClipboardContent) {
    synced = pasteboard.changeCount
    shared = content
  }
}
