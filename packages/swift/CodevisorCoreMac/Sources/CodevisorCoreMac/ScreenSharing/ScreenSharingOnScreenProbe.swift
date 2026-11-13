import AppKit

@MainActor
public final class ScreenSharingOnScreenProbe: NSView {
  public var onChange: ((Bool) -> Void)?
  public private(set) var isOnScreen = false

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    report()
  }

  public override func viewDidHide() {
    super.viewDidHide()
    report()
  }

  public override func viewDidUnhide() {
    super.viewDidUnhide()
    report()
  }

  public override func setFrameSize(_ size: NSSize) {
    super.setFrameSize(size)
    report()
  }

  public override func hitTest(_ point: NSPoint) -> NSView? { nil }

  public func retire() {
    settle(false)
    onChange = nil
  }

  private func report() {
    settle(window != nil && !isHiddenOrHasHiddenAncestor && !bounds.isEmpty)
  }

  private func settle(_ onScreen: Bool) {
    guard onScreen != isOnScreen else { return }
    isOnScreen = onScreen
    onChange?(onScreen)
  }
}
