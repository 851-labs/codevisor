import AppKit
import ScreenCaptureKit
import ScreenSharingBench

@MainActor
struct VCPLevelsWindow {
  private static let inset = 60.0
  private static let settle = Duration.seconds(1)

  let window: NSWindow
  private let screen: NSScreen

  init(showing view: NSView, on screen: NSScreen) {
    let scale = screen.backingScaleFactor
    let size = NSSize(width: CGFloat(VCPLevelsRamp.width) / scale, height: CGFloat(VCPLevelsRamp.height) / scale)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.hasShadow = false
    window.level = .screenSaver
    window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX + Self.inset, y: screen.frame.maxY - Self.inset))
    view.frame = NSRect(origin: .zero, size: size)
    window.contentView = view
    self.screen = screen
    NSApplication.shared.activate()
    window.orderFrontRegardless()
  }

  func settle() async throws {
    try await Task.sleep(for: Self.settle)
  }

  func close() {
    window.close()
  }

  func windowFilter() async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let shown = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
      throw BenchUsageError(message: "ScreenCaptureKit doesn't list the probe's window")
    }

    return SCContentFilter(desktopIndependentWindow: shown)
  }

  func displayFilter() async throws -> (filter: SCContentFilter, sourceRect: CGRect) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    guard let display = content.displays.first(where: { $0.displayID == number?.uint32Value }) else {
      throw BenchUsageError(message: "ScreenCaptureKit doesn't list the main display")
    }

    let size = window.frame.size
    return (
      SCContentFilter(display: display, excludingWindows: []),
      CGRect(origin: CGPoint(x: Self.inset, y: Self.inset), size: size)
    )
  }
}
