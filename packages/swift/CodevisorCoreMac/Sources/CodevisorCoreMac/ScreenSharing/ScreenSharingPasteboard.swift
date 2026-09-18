import AppKit
import ScreenSharing

@MainActor
final class ScreenSharingPasteboard {
  private let pasteboard: NSPasteboard
  var changeCount: Int { pasteboard.changeCount }
  init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

  func read() throws -> String {
    guard let text = pasteboard.string(forType: .string) else {
      throw ClipboardError("The clipboard does not contain plain text.")
    }
    guard text.utf8.count <= ScreenSharingClipboardMessage.maximumTextBytes else {
      throw ClipboardError("Clipboard text must be 64 KiB or smaller.")
    }
    return text
  }
  func write(_ text: String, expectedChangeCount: Int? = nil) throws {
    if let expectedChangeCount, expectedChangeCount != pasteboard.changeCount {
      throw ClipboardError("The local clipboard changed during transfer. Get the remote clipboard again.")
    }
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string) else { throw ClipboardError("Cannot prepare clipboard text.") }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { throw ClipboardError("Cannot write clipboard text.") }
  }
  struct ClipboardError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
