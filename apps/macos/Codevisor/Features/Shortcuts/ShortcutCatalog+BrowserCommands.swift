import AppKit
import SwiftUI

enum BrowserZoomCommand {
  case zoomIn, zoomOut, reset
}

extension ShortcutCatalog {
  static func browserZoomCommand(for event: NSEvent) -> BrowserZoomCommand? {
    if combo(for: .browserZoomIn)?.matches(event) == true
      || ShortcutCombo("+", [.command, .shift]).matches(event)
    {
      return .zoomIn
    }
    if combo(for: .browserZoomOut)?.matches(event) == true { return .zoomOut }
    if combo(for: .browserResetZoom)?.matches(event) == true { return .reset }
    return nil
  }
}
