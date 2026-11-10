import AppKit
import SwiftUI

struct KeyboardNavigationTabWatcher: NSViewRepresentable {
  let isActive: Bool
  let onRepeatedTab: () -> Void

  func makeNSView(context: Context) -> TabWatcherView {
    let view = TabWatcherView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: TabWatcherView, context: Context) {
    view.isActive = isActive
    view.onRepeatedTab = onRepeatedTab
  }

  final class TabWatcherView: NSView {
    private static let tabKeyCode: UInt16 = 48
    private static let repeatWindow: Duration = .seconds(1.5)

    var isActive = false
    var onRepeatedTab: (() -> Void)?
    private var monitor: Any?
    private var lastTab: ContinuousClock.Instant?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      removeMonitor()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.record(event)
        return event
      }
    }

    isolated deinit {
      removeMonitor()
    }

    private func record(_ event: NSEvent) {
      guard isNavigationTab(event) else { return }

      let now = ContinuousClock.now
      let isRepeat = lastTab.map { now - $0 < Self.repeatWindow } ?? false
      lastTab = isRepeat ? nil : now
      if isRepeat { onRepeatedTab?() }
    }

    private func isNavigationTab(_ event: NSEvent) -> Bool {
      guard isActive, let window, event.window === window, window.attachedSheet == nil else { return false }
      guard event.keyCode == Self.tabKeyCode else { return false }
      guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }

      return !consumesTab(window.firstResponder)
    }

    private func consumesTab(_ responder: NSResponder?) -> Bool {
      if responder is SubmittingTextView { return false }
      if let textView = responder as? NSTextView, textView.isFieldEditor { return false }
      return responder is NSTextInputClient
    }

    private func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
