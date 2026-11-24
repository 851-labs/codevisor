import AppKit

final class MenuOrigin {
  struct Anchor {
    let view: NSView
    let rect: CGRect
  }

  static let shared = MenuOrigin()

  private weak var window: NSWindow?
  private var point = CGPoint.zero
  private var observer: NSObjectProtocol?

  var anchor: Anchor? {
    pointed ?? Self.windowTop
  }

  private var pointed: Anchor? {
    guard let window, window.isVisible, let view = window.contentView else { return nil }

    return Anchor(view: view, rect: Self.rect(around: view.convert(point, from: nil)))
  }

  private static var windowTop: Anchor? {
    guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return nil }

    let inset = view.safeAreaInsets.top
    let top = view.isFlipped ? view.bounds.minY + inset : view.bounds.maxY - inset
    return Anchor(view: view, rect: rect(around: CGPoint(x: view.bounds.midX, y: top)))
  }

  private static func rect(around point: CGPoint) -> CGRect {
    CGRect(origin: point, size: .zero).insetBy(dx: -1, dy: -1)
  }

  func startTracking() {
    guard observer == nil else { return }

    observer = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.record() }
    }
  }

  private func record() {
    let location = NSEvent.mouseLocation
    window = NSApp.orderedWindows.first { Self.isMenuHost($0, at: location) }
    point = window?.convertPoint(fromScreen: location) ?? .zero
  }

  private static func isMenuHost(_ window: NSWindow, at location: CGPoint) -> Bool {
    window.isVisible && window.canBecomeMain && window.frame.contains(location)
  }
}
