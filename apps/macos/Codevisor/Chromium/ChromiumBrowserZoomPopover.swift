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
    private var panel: ZoomPanel?
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
    override func layout() { super.layout(); positionPanel() }

    func present() {
      guard let window, window.isKeyWindow else { return }
      dismissal?.cancel()
      if panel == nil {
        let popup = ZoomPanel(
          contentRect: NSRect(x: 0, y: 0, width: 132, height: 56),
          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.hidesOnDeactivate = true
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = false
        popup.appearance = window.effectiveAppearance
        popup.alphaValue = 0
        let controls = NSHostingView(
          rootView: ChromiumBrowserZoomControls(model: model)
            .onHover { [weak self] hovering in
              self?.hovering = hovering
              self?.scheduleDismissal()
            })
        controls.sizingOptions = []
        let glass = NSGlassEffectView(frame: NSRect(x: 12, y: 12, width: 108, height: 32))
        glass.cornerRadius = 16
        glass.contentView = controls
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 56))
        content.addSubview(glass)
        popup.contentView = content
        panel = popup
        positionPanel()
        window.addChildWindow(popup, ordered: .above)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
          [weak self] event in
          guard let self else { return event }
          if event.type == .keyDown {
            if event.window === self.window, event.keyCode == 53 { self.dismiss(); return nil }
          } else if event.window !== self.panel {
            self.dismiss()
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
      positionPanel()
      panel?.orderFront(nil)
      scheduleDismissal()
    }

    private func positionPanel() {
      guard let panel, let window else { return }
      let anchor = window.convertToScreen(convert(bounds, to: nil))
      panel.setFrame(
        NSRect(x: anchor.maxX - 120, y: anchor.minY - 58, width: 132, height: 56), display: true)
    }

    private func scheduleDismissal() {
      dismissal?.cancel()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        panel?.animator().alphaValue = 1
      }
      guard !hovering else { return }
      dismissal = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        await NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.15
          self?.panel?.animator().alphaValue = 0
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
      if let panel {
        panel.parent?.removeChildWindow(panel)
        panel.close()
      }
      panel = nil
      hovering = false
    }

    deinit {
      dismissal?.cancel()
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
  }

  final class ZoomPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }
}

private struct ChromiumBrowserZoomControls: View {
  @Bindable var model: ChromiumBrowserModel

  var body: some View {
    HStack(spacing: 0) {
      Button {
        model.zoom(.zoomOut)
      } label: {
        Image(systemName: "minus").frame(width: 34, height: 32)
      }
      .disabled(!model.canZoomOut)
      .help("Zoom Out (⌘−)")
      .accessibilityLabel("Zoom Out (⌘−)")
      Button {
        model.zoom(.reset)
      } label: {
        Text("\(model.zoomPercent)%")
          .font(.system(size: 11, weight: .medium).monospacedDigit())
          .frame(width: 40, height: 32)
      }
      .disabled(!model.canResetZoom)
      .help("Reset Zoom (⌘0)")
      .accessibilityLabel("Zoom \(model.zoomPercent)%, reset zoom")
      Button {
        model.zoom(.zoomIn)
      } label: {
        Image(systemName: "plus").frame(width: 34, height: 32)
      }
      .disabled(!model.canZoomIn)
      .help("Zoom In (⌘+)")
      .accessibilityLabel("Zoom In (⌘+)")
    }
    .buttonStyle(.plain)
    .fixedSize()
  }
}
