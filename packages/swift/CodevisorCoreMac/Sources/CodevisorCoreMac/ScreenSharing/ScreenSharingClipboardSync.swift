import ScreenSharing

/// Shared clipboard, one side's bookkeeping: which local copies the other side already has.
/// Checking the pasteboard's change count is cheap and never reads its contents; the text is read
/// only after a copy. Text this side wrote for the other counts as theirs, so it never bounces back.
@MainActor
final class ScreenSharingClipboardSync {
  private let pasteboard: ScreenSharingPasteboard
  /// The change count the other side has; nil until anything was shared, so the first check sends.
  private var synced: Int?
  /// The change count and text being sent.
  private var sending: (count: Int, text: String)?
  /// The text both sides last had. When both share one pasteboard (a Mac viewing itself), each
  /// write is a new change on the other side too; the same text settles instead of going round.
  private var shared: String?
  var isSending: Bool { sending != nil }

  init(pasteboard: ScreenSharingPasteboard, synced: Int?) {
    self.pasteboard = pasteboard
    self.synced = synced
  }

  /// Starts over: nil shares what the clipboard holds now; the current count, only later copies.
  func reset(synced: Int?) {
    self.synced = synced
    sending = nil
    shared = nil
  }

  /// The text to send, when the clipboard changed since the other side last had it. A private
  /// item, one with no text or too much, or the text both sides already have counts as had.
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

  /// The send ended. A failed one waits for the next copy rather than retrying.
  func sent(succeeded: Bool) {
    if let sending {
      synced = sending.count
      if succeeded { shared = sending.text }
    }
    sending = nil
  }

  /// This side wrote the other's text.
  func wrote(_ text: String) {
    synced = pasteboard.changeCount
    shared = text
  }
}
