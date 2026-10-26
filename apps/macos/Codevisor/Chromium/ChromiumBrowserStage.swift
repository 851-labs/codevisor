import AppKit

final class ChromiumBrowserStage: NSView {
  private static let warmLifetime: Duration = .seconds(10)
  private var cooling: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var closeObserver: (any NSObjectProtocol)?

  static func stage(for window: NSWindow) -> ChromiumBrowserStage? {
    guard window.isVisible, let content = window.contentView, let root = content.superview else { return nil }
    if let existing = root.subviews.lazy.compactMap({ $0 as? ChromiumBrowserStage }).first { return existing }
    let stage = ChromiumBrowserStage(frame: content.frame)
    stage.autoresizingMask = [.width, .height]
    root.addSubview(stage, positioned: .above, relativeTo: content)
    stage.releaseViewsWhenClosing(window)
    return stage
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func keepWarm(_ view: NSView, beforeHiding snapshot: @escaping () async -> Void) {
    stopCooling(view)
    view.alphaValue = 0
    addSubview(view)
    view.isHidden = false
    let id = ObjectIdentifier(view)
    cooling[id] = Task { [weak self, weak view] in
      try? await Task.sleep(for: Self.warmLifetime)
      guard !Task.isCancelled else { return }
      await snapshot()
      guard !Task.isCancelled, let self else { return }
      self.cooling[id] = nil
      guard let view, view.superview === self else { return }
      view.isHidden = true
    }
  }

  func park(_ view: NSView) {
    stopCooling(view)
    addSubview(view)
    view.isHidden = true
  }

  private func stopCooling(_ view: NSView) {
    cooling.removeValue(forKey: ObjectIdentifier(view))?.cancel()
  }

  private func releaseViewsWhenClosing(_ window: NSWindow) {
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        for task in self.cooling.values { task.cancel() }
        self.cooling = [:]
        for view in self.subviews { view.removeFromSuperview() }
        self.removeFromSuperview()
      }
    }
  }

  isolated deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
}
