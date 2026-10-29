import AppKit

final class PlayerStubWindow: NSWindow {
  init(screen: NSScreen?) {
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    level = .mainMenu
    backgroundColor = .black
    let label = NSTextField(labelWithString: "CodevisorBench player")
    label.textColor = .white
    contentView = label
  }

  override var canBecomeKey: Bool { true }
}
