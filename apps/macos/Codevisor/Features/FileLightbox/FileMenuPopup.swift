import AppKit
import CodevisorUI
import StreamMarkdown

enum FileMenuPopup {
  static func present(_ menu: FileMenu) {
    let popup = MarkdownLinkMenu.menu(for: menu.markdownItems(share: MacFileTransfers.transfers.share))
    guard let click = NSApp.currentEvent, let view = click.window?.contentView else {
      popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
      return
    }

    NSMenu.popUpContextMenu(popup, with: click, for: view)
  }
}
