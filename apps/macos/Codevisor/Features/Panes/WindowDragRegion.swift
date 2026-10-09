import AppKit
import SwiftUI

/// Empty toolbar space that behaves like the titlebar: dragging moves the
/// window, and a double-click does what the user chose in System Settings
/// (zoom, minimize, or nothing). Views inside a toolbar item's scroll view
/// swallow the mouse otherwise, so the strip's empty space would be dead.
struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ nsView: DragView, context: Context) {}

  final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
      guard let window else { return super.mouseDown(with: event) }
      if event.clickCount == 2 {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
        return
      }
      window.performDrag(with: event)
    }
  }
}
