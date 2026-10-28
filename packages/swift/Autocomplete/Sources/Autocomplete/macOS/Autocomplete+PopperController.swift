#if canImport(AppKit)
  import AppKit
  import SwiftUI

  extension Autocomplete {
    @MainActor
    final class PopperController {
      static let nativeMenuFadeOutDuration: TimeInterval = 0.24
      static let nativeMenuFadeOutCurve = CAMediaTimingFunction(name: .default)

      private(set) var panel: PopperPanel?
      private(set) var fadingPanel: PopperPanel?
      private weak var anchor: NSView?
      private var content = AnyView(EmptyView())
      private var environment = EnvironmentValues()
      private var heightLimit: CGFloat?
      private var wantsPresentation = false
      private var edge = PopperPlacement.Edge.below
      private var isPlacing = false
      private var onDismiss: () -> Void = {}
      private var clickMonitor: Any?
      private var isClosingTriggerClick = false
      private var nextPressMonitor: Any?
      private var observers: [NSObjectProtocol] = []

      func update(
        isPresented: Bool, content: AnyView, environment: EnvironmentValues, anchor: NSView,
        onDismiss: @escaping () -> Void
      ) {
        self.content = content
        self.environment = environment
        self.anchor = anchor
        self.onDismiss = onDismiss
        wantsPresentation = isPresented
        sync()
      }

      func sync() {
        guard wantsPresentation else { return hide() }
        guard let panel, panel.parent === anchor?.window else { return reopen() }
        panel.host.rootView = limitedContent()
        place()
      }

      func dismiss() {
        guard panel != nil else { return }
        hide()
        onDismiss()
      }

      func tearDown() {
        wantsPresentation = false
        endClosingTriggerClick()
        if let fadingPanel { remove(fadingPanel) }
        guard let panel else { return }
        remove(panel)
        Task { @MainActor [onDismiss] in onDismiss() }
      }

      func anchorDidMove() {
        guard panel != nil else { return }
        place()
      }

      func dismissForClickOutside(_ event: NSEvent) -> NSEvent? {
        let point = Self.screenLocation(of: event)
        guard let panel, !panel.frame.contains(point) else { return event }
        if anchorFrame()?.contains(point) == true { markClosingTriggerClick() }
        dismiss()
        return event
      }

      func consumeClosingTriggerClick() -> Bool {
        guard isClosingTriggerClick else { return false }
        endClosingTriggerClick()
        return true
      }

      func endClosingTriggerClick() {
        isClosingTriggerClick = false
        if let nextPressMonitor { NSEvent.removeMonitor(nextPressMonitor) }
        nextPressMonitor = nil
      }

      private func markClosingTriggerClick() {
        isClosingTriggerClick = true
        DispatchQueue.main.async { [weak self] in
          guard let self, isClosingTriggerClick, nextPressMonitor == nil else { return }
          nextPressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            self?.endClosingTriggerClick()
            return event
          }
        }
      }

      private func reopen() {
        if let panel { remove(panel) }
        show()
      }

      private func show() {
        guard let parent = anchor?.window, parent.isVisible else { return }
        if let fadingPanel { remove(fadingPanel) }
        heightLimit = nil
        let panel = makePanel()
        self.panel = panel
        edge = .below
        place()
        panel.attach(to: parent)
        panel.makeKey()
        startObserving(parent)
      }

      private func makePanel() -> PopperPanel {
        let panel = PopperPanel(content: limitedContent())
        panel.onResignKey = { [weak self, weak panel] in
          guard let self, self.panel === panel else { return }
          dismiss()
        }
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.host.onSizeChange = { [weak self] in self?.place() }
        return panel
      }

      private func hide() {
        guard let panel else { return }
        self.panel = nil
        stopObserving()
        if panel.isKeyWindow { panel.parent?.makeKey() }
        fadeOut(panel)
      }

      private func fadeOut(_ panel: PopperPanel) {
        fadingPanel = panel
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
          context.duration = Self.nativeMenuFadeOutDuration
          context.timingFunction = Self.nativeMenuFadeOutCurve
          panel.fade(to: 0)
        } completionHandler: { [weak self, weak panel] in
          MainActor.assumeIsolated {
            guard let self, let panel, self.fadingPanel === panel else { return }
            self.remove(panel)
          }
        }
      }

      private func remove(_ panel: PopperPanel) {
        if self.panel === panel {
          self.panel = nil
          stopObserving()
        }
        if fadingPanel === panel { fadingPanel = nil }
        panel.detach()
        panel.contentView = nil
      }

      private func place() {
        guard !isPlacing, let panel, let window = anchor?.window, let anchorFrame = anchorFrame() else { return }
        isPlacing = true
        defer { isPlacing = false }
        guard let visibleFrame = Self.screen(containing: anchorFrame, fallback: window)?.visibleFrame else { return }
        limitHeight(to: PopperPlacement.availableHeight(anchor: anchorFrame, visibleFrame: visibleFrame), of: panel)
        let placement = PopperPlacement.resolve(
          size: panel.host.fittingSize, anchor: anchorFrame, visibleFrame: visibleFrame,
          layoutDirection: environment.layoutDirection, preferring: edge)
        edge = placement.edge
        guard panel.frame != placement.frame else { return }
        panel.setFrame(placement.frame, display: true)
      }

      private func limitHeight(to limit: CGFloat, of panel: PopperPanel) {
        guard heightLimit != limit else { return }
        heightLimit = limit
        panel.host.rootView = limitedContent()
      }

      private func limitedContent() -> AnyView {
        var environment = environment
        if let heightLimit {
          let metrics = environment.autocompleteStyle.metrics
          environment.autocompleteStyle.metrics.maximumHeight = min(metrics.maximumHeight, heightLimit)
        }
        return AnyView(content.environment(\.self, environment))
      }

      private static func screen(containing rect: CGRect, fallback window: NSWindow) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen
      }

      private func anchorFrame() -> CGRect? {
        guard let anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
      }

      private static func screenLocation(of event: NSEvent) -> CGPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
      }

      private func startObserving(_ parent: NSWindow) {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
          [weak self] event in
          self?.dismissForClickOutside(event) ?? event
        }
        observers = [
          observe(NSWindow.didResizeNotification, of: parent) { $0.place() },
          observe(NSWindow.willCloseNotification, of: parent) { $0.dismiss() },
          observe(NSWindow.willMiniaturizeNotification, of: parent) { $0.dismiss() },
          observe(NSApplication.didResignActiveNotification, of: NSApp) { $0.dismiss() },
        ]
      }

      private func observe(
        _ name: Notification.Name, of object: AnyObject?, perform: @escaping @MainActor (PopperController) -> Void
      ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            perform(self)
          }
        }
      }

      private func stopObserving() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
      }
    }
  }
#endif
