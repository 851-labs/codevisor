import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  override func menu(for event: NSEvent) -> NSMenu? {
    messageMenu(atBubbleUnder: event) ?? super.menu(for: event)
  }

  func messageMenu(forRowKey key: String) -> NSMenu? {
    guard let (id, text) = message(forRowKey: key), !text.isEmpty else { return nil }
    let menu = NSMenu()
    let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMessage(_:)), keyEquivalent: "")
    copyItem.target = self
    copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
    copyItem.representedObject = text
    menu.addItem(copyItem)
    TranscriptMessageMenuHighlight.shared.highlight(id, whileShowing: menu)
    return menu
  }

  @objc func copyMessage(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func messageMenu(atBubbleUnder event: NSEvent) -> NSMenu? {
    for (key, host) in mountedHosts where !host.isHidden {
      let point = host.convert(event.locationInWindow, from: nil)
      guard host.bounds.contains(point) else { continue }
      guard Self.bubbleFrames(in: host, relativeTo: host).contains(where: { $0.contains(point) }) else {
        return nil
      }
      return messageMenu(forRowKey: key)
    }
    return nil
  }

  private func message(forRowKey key: String) -> (id: String, text: String)? {
    switch rowByKey[key]?.content {
    case let .message(.user(message), _) where !message.isEvent: (message.id.uuidString, message.text)
    case let .optimistic(message): (message.id.uuidString, message.text)
    case let .botMessage(message, _) where message.sender != .notice: (message.id, message.text)
    default: nil
    }
  }

  private static func bubbleFrames(in view: NSView, relativeTo host: NSView) -> [CGRect] {
    view.subviews.flatMap { subview in
      subview is UserBubbleAnchorView
        ? [subview.convert(subview.bounds, to: host)]
        : bubbleFrames(in: subview, relativeTo: host)
    }
  }
}
