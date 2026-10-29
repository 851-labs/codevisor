import AppKit
import ScreenSharing

final class BarcodeWindow: NSWindow {
  private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

  let view: ScreenSharingMetalView
  var onKeyDown: (() -> Void)?

  static func presented(on displayID: CGDirectDisplayID) throws -> BarcodeWindow {
    let window = try BarcodeWindow(screen: try screen(displayID: displayID))
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.activate()
    application.presentationOptions = [.hideDock, .hideMenuBar]
    window.makeKeyAndOrderFront(nil)
    return window
  }

  private init(screen: NSScreen) throws {
    view = try ScreenSharingMetalView(
      mailbox: ScreenSharingFrameMailbox(), metrics: ScreenSharingMetrics(), renderOnArrival: true)
    super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    level = .mainMenu
    backgroundColor = .black
    contentView = view
    setFrame(screen.frame, display: true)
  }

  override var canBecomeKey: Bool { true }

  override func keyDown(with event: NSEvent) {
    onKeyDown?()
  }

  var pixelSize: CGSize {
    convertToBacking(view.bounds).size
  }

  private static func screen(displayID: CGDirectDisplayID) throws -> NSScreen {
    let screen = NSScreen.screens.first { $0.deviceDescription[screenNumberKey] as? CGDirectDisplayID == displayID }
    guard let screen else { throw BenchUsageError(message: "no screen for display \(displayID)") }

    return screen
  }
}
