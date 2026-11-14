import AppKit

@MainActor
public final class ScreenSharingOnScreenProbe: NSView {
  public var onChange: ((Bool) -> Void)?
  public private(set) var isOnScreen = false
  private var windowVisibility: NSKeyValueObservation?

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    stopWatchingWindow()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    watchWindow()
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
    stopWatchingWindow()
    settle(false)
    onChange = nil
  }

  private func watchWindow() {
    guard let window else { return }

    windowVisibility = window.observe(\.isVisible) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.report() }
    }
    for change in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: change, object: window)
    }
  }

  private func stopWatchingWindow() {
    windowVisibility = nil
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func windowChanged() {
    report()
  }

  private var isInAShowingWindow: Bool {
    guard let window else { return false }

    return window.isVisible && !window.isMiniaturized
  }

  private func report() {
    settle(isInAShowingWindow && !isHiddenOrHasHiddenAncestor && !bounds.isEmpty)
  }

  private func settle(_ onScreen: Bool) {
    guard onScreen != isOnScreen else { return }

    isOnScreen = onScreen
    onChange?(onScreen)
  }
}
