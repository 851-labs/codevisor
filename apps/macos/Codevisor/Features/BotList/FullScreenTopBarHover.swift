import AppKit
import SwiftUI

struct FullScreenTopBarHover: NSViewRepresentable {
  let bandHeight: CGFloat
  let onChange: @MainActor (Bool) -> Void

  nonisolated static func isPointerInTopBar(
    _ pointer: CGPoint, windowFrame: CGRect, screenFrame: CGRect, bandHeight: CGFloat
  ) -> Bool {
    screenFrame.contains(pointer) && pointer.y >= windowFrame.maxY - bandHeight
  }

  func makeNSView(context: Context) -> Probe {
    Probe(bandHeight: bandHeight, onChange: onChange)
  }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.bandHeight = bandHeight
    probe.onChange = onChange
  }

  final class Probe: NSView {
    private static let pollInterval: TimeInterval = 0.1

    var bandHeight: CGFloat
    var onChange: @MainActor (Bool) -> Void
    private var isHovering = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(bandHeight: CGFloat, onChange: @escaping @MainActor (Bool) -> Void) {
      self.bandHeight = bandHeight
      self.onChange = onChange
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
      timer?.invalidate()
      observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observeFullScreen()
      setPolling(window?.styleMask.contains(.fullScreen) ?? false)
    }

    private func observeFullScreen() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      observers = [
        observe(NSWindow.didEnterFullScreenNotification, of: window, polling: true),
        observe(NSWindow.willExitFullScreenNotification, of: window, polling: false),
      ]
    }

    private func observe(_ name: NSNotification.Name, of window: NSWindow, polling: Bool) -> NSObjectProtocol {
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setPolling(polling) }
      }
    }

    private func setPolling(_ polling: Bool) {
      timer?.invalidate()
      timer = nil
      guard polling else { return report(false) }
      timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.poll() }
      }
    }

    private func poll() {
      guard let window, let screen = window.screen else { return report(false) }
      report(
        FullScreenTopBarHover.isPointerInTopBar(
          NSEvent.mouseLocation, windowFrame: window.frame, screenFrame: screen.frame, bandHeight: bandHeight
        )
      )
    }

    private func report(_ hovering: Bool) {
      guard hovering != isHovering else { return }
      isHovering = hovering
      onChange(hovering)
    }
  }
}
