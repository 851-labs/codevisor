import AppKit
import SwiftUI

/// Anchor the zoom bubble to the address bar without taking focus from CEF.
struct ChromiumBrowserZoomPopover: NSViewRepresentable {
  let model: ChromiumBrowserModel
  let request: Int
  let editing: Bool
  let loading: Bool

  func makeNSView(context: Context) -> Anchor {
    Anchor(model: model, request: request, editing: editing, loading: loading)
  }

  func updateNSView(_ nsView: Anchor, context: Context) {
    if (editing && !nsView.editing) || (loading && !nsView.loading) { nsView.dismiss() }
    nsView.editing = editing
    nsView.loading = loading
    if nsView.request != request {
      nsView.request = request
      nsView.present()
    }
  }

  static func dismantleNSView(_ nsView: Anchor, coordinator: ()) { nsView.dismiss() }

  final class Anchor: NSView {
    let model: ChromiumBrowserModel
    var request: Int
    var editing: Bool
    var loading: Bool
    private var bubble: NSView?
    private var dismissal: Task<Void, Never>?
    private var hovering = false
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(model: ChromiumBrowserModel, request: Int, editing: Bool, loading: Bool) {
      self.model = model
      self.request = request
      self.editing = editing
      self.loading = loading
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow !== window { dismiss() }
      super.viewWillMove(toWindow: newWindow)
    }
    override func layout() { super.layout(); positionBubble() }

    func present() {
      guard let window, window.isKeyWindow else { return }
      dismissal?.cancel()
      if bubble == nil {
        guard let content = window.contentView else { return }
        // Keep the interactive glass in the key window's view hierarchy
        // so it shares the address bar's active appearance.
        let controls = NSHostingView(
          rootView: ChromiumBrowserZoomControls(model: model)
            .onHover { [weak self] hovering in
              self?.hovering = hovering
              self?.scheduleDismissal()
            }
            .padding(12))
        controls.sizingOptions = [.intrinsicContentSize]
        controls.setFrameSize(controls.fittingSize)
        controls.alphaValue = 0
        bubble = controls
        content.addSubview(controls, positioned: .above, relativeTo: nil)
        positionBubble()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
          [weak self] event in
          guard let self else { return event }
          if event.type == .keyDown {
            if event.window === self.window, event.keyCode == 53 { self.dismiss(); return nil }
          } else if let bubble = self.bubble {
            if event.window !== self.window
              || !bubble.bounds.contains(bubble.convert(event.locationInWindow, from: nil))
            {
              self.dismiss()
            }
          }
          return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
          observers.append(
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
              MainActor.assumeIsolated { self?.dismiss() }
            })
        }
      }
      positionBubble()
      scheduleDismissal()
    }

    private func positionBubble() {
      guard let bubble, let content = bubble.superview else { return }
      let anchor = convert(bounds, to: content)
      let size = bubble.frame.size
      let y = content.isFlipped ? anchor.maxY + 2 : anchor.minY - size.height - 2
      bubble.setFrameOrigin(NSPoint(x: anchor.maxX - size.width + 12, y: y))
    }

    private func scheduleDismissal() {
      dismissal?.cancel()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        bubble?.animator().alphaValue = 1
      }
      guard !hovering else { return }
      dismissal = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        await NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.15
          self?.bubble?.animator().alphaValue = 0
        }
        guard !Task.isCancelled else { return }
        self?.dismiss()
      }
    }

    func dismiss() {
      dismissal?.cancel()
      dismissal = nil
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
      bubble?.removeFromSuperview()
      bubble = nil
      hovering = false
    }

    deinit {
      dismissal?.cancel()
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
  }

}
