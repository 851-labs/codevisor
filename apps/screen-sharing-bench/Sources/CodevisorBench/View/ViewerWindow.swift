import AppKit
import ScreenSharing

final class ViewerWindow: NSWindow {
  static func presented() throws -> ViewerWindow {
    guard let screen = NSScreen.main else { throw BenchUsageError(message: "this Mac has no screen") }

    let window = ViewerWindow(screen: screen)
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
    BenchPresentation.hideMenuBarOnceActive()
    return window
  }

  private init(screen: NSScreen) {
    super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    level = .screenSaver
    backgroundColor = .black
    setFrame(screen.frame, display: true)
  }

  override var canBecomeKey: Bool { true }

  override func close() {
    super.close()
    BenchPresentation.restoreMenuBar()
  }

  func show(_ surface: ScreenSharingVideoSurface) {
    contentView = surface
    surface.frame = contentLayoutRect
  }

  var pixelSize: CGSize {
    convertToBacking(frame).size
  }
}
