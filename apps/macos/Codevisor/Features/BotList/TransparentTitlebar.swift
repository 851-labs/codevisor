import AppKit
import SwiftUI

struct TransparentTitlebar: NSViewRepresentable {
  let isTransparent: Bool

  final class Probe: NSView {
    var isTransparent = false {
      didSet { apply() }
    }

    private var isFullScreen = false {
      didSet { apply() }
    }

    private var observers: [NSObjectProtocol] = []

    isolated deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
      observeFullScreen()
      apply()
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

    private func apply() {
      let transparent = isTransparent && !isFullScreen
      guard let window, window.titlebarAppearsTransparent != transparent else { return }
      window.titlebarAppearsTransparent = transparent
    }
  }

  func makeNSView(context: Context) -> Probe {
    let probe = Probe()
    probe.isTransparent = isTransparent
    return probe
  }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.isTransparent = isTransparent
  }
}
