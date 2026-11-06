import AppKit
import SwiftUI

struct FullScreenTopBarHover: NSViewRepresentable {
  let bandHeight: CGFloat
  let onChange: @MainActor (Bool) -> Void

  func makeNSView(context: Context) -> Probe {
    Probe(watcher: TopBandPointerWatcher(bandHeight: bandHeight, onChange: onChange))
  }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.watcher.bandHeight = bandHeight
  }

  final class Probe: NSView {
    let watcher: TopBandPointerWatcher
    private var observers: [NSObjectProtocol] = []

    init(watcher: TopBandPointerWatcher) {
      self.watcher = watcher
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observeFullScreen()
      setWatching(window?.styleMask.contains(.fullScreen) ?? false)
    }

    private func observeFullScreen() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      observers = [
        observe(NSWindow.didEnterFullScreenNotification, of: window, watching: true),
        observe(NSWindow.willExitFullScreenNotification, of: window, watching: false),
      ]
    }

    private func observe(_ name: NSNotification.Name, of window: NSWindow, watching: Bool) -> NSObjectProtocol {
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setWatching(watching) }
      }
    }

    private func setWatching(_ watching: Bool) {
      guard watching else { return watcher.stop() }

      watcher.watch(window)
    }
  }
}
