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

    isolated deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
      observeFullScreen()
      update()
    }

    private func observeFullScreen() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      observers = [
        observe(NSWindow.willEnterFullScreenNotification, of: window, isFullScreen: true),
        observe(NSWindow.didExitFullScreenNotification, of: window, isFullScreen: false),
      ]
    }

    private func observe(_ name: NSNotification.Name, of window: NSWindow, isFullScreen: Bool) -> NSObjectProtocol {
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.isFullScreen = isFullScreen }
      }
    }

    private var wantsTransparency: Bool {
      isTransparent && !isFullScreen
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
      let transparent = wantsTransparency && !isPointerInTopBar
      guard let window, window.titlebarAppearsTransparent != transparent else { return }
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
