#if os(macOS)
  import AppKit
  import WebKit

  final class PluginAppNativeWebView: WKWebView {
    var contextActions: [PluginAppContextAction] = []
    private var onVisible: (() -> Void)?
    private var occlusionObserver: (any NSObjectProtocol)?

    var isWindowVisible: Bool { window?.occlusionState.contains(.visible) == true }

    func whenVisible(_ action: @escaping () -> Void) {
      onVisible = action
      notifyIfVisible()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
      occlusionObserver = nil
      guard let window else { return }
      occlusionObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.notifyIfVisible() }
      }
      notifyIfVisible()
    }

    private func notifyIfVisible() {
      guard isWindowVisible, let onVisible else { return }
      self.onVisible = nil
      onVisible()
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
      super.willOpenMenu(menu, with: event)
      guard !contextActions.isEmpty else { return }
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      for action in contextActions { menu.addItem(PluginAppMenuItem(action)) }
    }
  }

  @MainActor
  private final class PluginAppMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ action: PluginAppContextAction) {
      handler = action.perform
      super.init(title: action.title, action: #selector(runHandler), keyEquivalent: "")
      target = self
      image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func runHandler() { handler() }
  }
#endif
