import AppKit

final class StagedWindow: NSWindow {
  var shows = true {
    willSet { willChangeValue(forKey: "visible") }
    didSet { didChangeValue(forKey: "visible") }
  }
  private var minimised = false

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered,
      defer: true)
    isReleasedWhenClosed = false
  }

  override var isVisible: Bool { shows }

  override var isMiniaturized: Bool { minimised }

  func minimise(_ minimised: Bool) {
    self.minimised = minimised
    let change = minimised ? NSWindow.didMiniaturizeNotification : NSWindow.didDeminiaturizeNotification
    NotificationCenter.default.post(name: change, object: self)
  }
}
