import AppKit

@MainActor
final class ChromiumBackgroundHost {
  private var window: NSWindow?

  func host(_ view: NSView) {
    guard view.window == nil else { return }
    hostWindow(sized: view.bounds).contentView?.addSubview(view)
  }

  func close() {
    window?.close()
    window = nil
  }

  private func hostWindow(sized frame: NSRect) -> NSWindow {
    if let window { return window }
    let created = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    created.isReleasedWhenClosed = false
    created.isExcludedFromWindowsMenu = true
    window = created
    return created
  }
}
