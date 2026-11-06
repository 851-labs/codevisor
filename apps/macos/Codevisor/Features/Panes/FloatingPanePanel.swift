import AppKit

final class FloatingPanePanel: NSPanel {
  private static let initialSize = NSSize(width: 480, height: 560)
  private static let minimumSize = NSSize(width: 320, height: 240)

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: Self.initialSize),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: true
    )
    isFloatingPanel = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isRestorable = false
    tabbingMode = .disallowed
    collectionBehavior = [.fullScreenAuxiliary]
    contentMinSize = Self.minimumSize
  }

  override func cancelOperation(_ sender: Any?) {}

  func resetSize() {
    setContentSize(Self.initialSize)
  }
}
