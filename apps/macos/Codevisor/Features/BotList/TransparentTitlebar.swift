import AppKit
import SwiftUI

struct TransparentTitlebar: NSViewRepresentable {
  let isTransparent: Bool
  let hoverBandHeight: CGFloat

  final class Probe: NSView {
    var isTransparent = false {
      didSet { update() }
    }

    private var isFullScreen = false {
      didSet { update() }
    }

    private var isPointerInTopBar = false {
      didSet { apply() }
    }

    private(set) lazy var hover = TopBandPointerWatcher(bandHeight: 0) { [weak self] in
      self?.isPointerInTopBar = $0
    }

    private var observers: [NSObjectProtocol] = []
    private var ownsTitlebar = false

    isolated deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
      observeWindow()
      update()
    }

    private func observeWindow() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      observers = [
        observe(NSWindow.willEnterFullScreenNotification, of: window) { $0.isFullScreen = true },
        observe(NSWindow.didExitFullScreenNotification, of: window) { $0.isFullScreen = false },
        observe(NSWindow.didBecomeMainNotification, of: window) { $0.apply() },
        observe(NSWindow.didResignMainNotification, of: window) { $0.apply() },
        observe(NSApplication.didBecomeActiveNotification, of: NSApp) { $0.apply() },
        observe(NSApplication.didResignActiveNotification, of: NSApp) { $0.apply() },
      ]
    }

    private func observe(
      _ name: NSNotification.Name, of object: AnyObject?, apply change: @escaping @MainActor (Probe) -> Void
    ) -> NSObjectProtocol {
      NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          change(self)
        }
      }
    }

    private var wantsTransparency: Bool {
      isTransparent && !isFullScreen
    }

    private var appearsActive: Bool {
      NSApp.isActive && window?.isMainWindow == true
    }

    private func update() {
      watchHover()
      apply()
    }

    private func watchHover() {
      guard wantsTransparency else { return hover.stop() }
      guard !hover.isWatching(window) else { return }

      hover.watch(window)
    }

    private func apply() {
      guard let window, wantsTransparency || ownsTitlebar else { return }
      ownsTitlebar = wantsTransparency
      let transparent = wantsTransparency && appearsActive && !isPointerInTopBar
      guard window.titlebarAppearsTransparent != transparent else { return }
      window.titlebarAppearsTransparent = transparent
    }
  }

  func makeNSView(context: Context) -> Probe {
    let probe = Probe()
    probe.hover.bandHeight = hoverBandHeight
    probe.isTransparent = isTransparent
    return probe
  }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.hover.bandHeight = hoverBandHeight
    probe.isTransparent = isTransparent
  }
}
