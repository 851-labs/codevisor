import AppKit
import ApplicationServices
import Foundation

private let computerUsePasteLock = NSLock()

/// Restore only our temporary clipboard. A copy made by the user or another
/// app while pasting must win over the saved contents.
func computerUseShouldRestoreClipboard(writtenChangeCount: Int, currentChangeCount: Int) -> Bool {
  writtenChangeCount == currentChangeCount
}

extension ComputerUseBridge {
  func pasteText(arguments: [String: Any], app: NSRunningApplication, application: AXUIElement) throws -> [String: Any]
  {
    guard let text = arguments["text"] as? String else {
      throw BridgeError("text is required as the plain-text fallback")
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
      throw BridgeError("Pasting requires delivery_mode foreground. The app will retain focus.")
    }
    computerUsePasteLock.lock()
    defer { computerUsePasteLock.unlock() }
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
    let before = focused.flatMap { stringAttribute($0, kAXValueAttribute) }
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    if let html = arguments["html"] as? String { item.setString(html, forType: .html) }
    pasteboard.clearContents()
    var written = pasteboard.changeCount
    defer {
      if computerUseShouldRestoreClipboard(writtenChangeCount: written, currentChangeCount: pasteboard.changeCount) {
        let items = saved.map { values in
          let restored = NSPasteboardItem()
          for (type, data) in values { restored.setData(data, forType: type) }
          return restored
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
      }
    }
    let prepared = pasteboard.writeObjects([item])
    written = pasteboard.changeCount
    guard prepared else { throw BridgeError("Unable to prepare the clipboard for pasting") }
    try keyPress("super+v", pid: app.processIdentifier, global: true)
    // Wait for the target to consume the paste before restoring the clipboard.
    // A non-text target may not expose an acknowledgement; report uncertainty.
    var verified = false
    for _ in 0..<50 {
      Thread.sleep(forTimeInterval: 0.02)
      if let focused, let after = stringAttribute(focused, kAXValueAttribute),
        after != before, after.contains(text)
      {
        verified = true
        break
      }
    }
    return actionResultMetadata(kind: "paste_text", path: "clipboard", deliveryMode: "foreground", verified: verified)
  }
}
