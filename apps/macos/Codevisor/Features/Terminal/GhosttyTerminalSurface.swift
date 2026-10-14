import AppKit
import Combine
import GhosttyKit
import CodevisorCore
import os

@MainActor
private final class CodevisorGhosttySurfaceView: Ghostty.SurfaceView {
  var onClear: (() -> Void)?
  var onUse: (() -> Void)?
  var onUserInput: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    onUserInput?()
    super.keyDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    onUserInput?()
    super.mouseUp(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    onUserInput?()
    super.mouseDragged(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    onUserInput?()
    super.rightMouseDown(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    onUserInput?()
    super.otherMouseDown(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    onUserInput?()
    super.scrollWheel(with: event)
  }
  var onRestartRequest: (() -> Void)?
  var onPaneCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      onFocusChanged?(true)
      onUse?()
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted {
      onFocusChanged?(false)
    }
    return accepted
  }

  private var lastForwardedSize: NSSize = .zero
  private var pendingSizeUpdate = false

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    guard newSize != lastForwardedSize else { return }
    lastForwardedSize = newSize
    scheduleSizeUpdate()
  }

  private func scheduleSizeUpdate() {
    guard !pendingSizeUpdate else { return }
    pendingSizeUpdate = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingSizeUpdate = false
      self.lastForwardedSize = self.frame.size
      self.sizeDidChange(self.frame.size)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    lastForwardedSize = frame.size
    sizeDidChange(frame.size)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    onUserInput?()
    if window?.firstResponder === self { onUse?() }
    focusForInput()
    super.mouseDown(with: event)
  }

  func focusForInput() {
    window?.makeFirstResponder(self)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self { onUserInput?() }
    if event.type == .keyDown, window?.firstResponder === self, let onClear,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers == "k"
    {
      onClear()
      return true
    }
    if event.type == .keyDown, window?.firstResponder === self, let onPaneCommand,
      let command = ShortcutCatalog.paneCommand(for: event)
    {
      onPaneCommand(command)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    menu.addItem(.separator())
    let item = menu.addItem(
      withTitle: "Restart Terminal",
      action: #selector(requestRestart(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.setImageIfDesired(systemSymbolName: "arrow.trianglehead.counterclockwise")
    return menu
  }

  @objc private func requestRestart(_ sender: Any?) {
    onRestartRequest?()
  }
}

@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
  private var surfaceView: CodevisorGhosttySurfaceView?
  private var cancellables = Set<AnyCancellable>()
  private let controller: TerminalController
  private let hostIO: GhosttyHostIO
  private var renderer: GhosttySurfaceRenderer?

  var nsView: NSView { surfaceView ?? NSView() }

  var onRestartRequest: (() -> Void)? {
    get { surfaceView?.onRestartRequest }
    set { surfaceView?.onRestartRequest = newValue }
  }

  var onPaneCommand: ((PaneGroupCommand) -> Void)? {
    get { surfaceView?.onPaneCommand }
    set { surfaceView?.onPaneCommand = newValue }
  }

  var onFocusChanged: ((Bool) -> Void)? {
    get { surfaceView?.onFocusChanged }
    set { surfaceView?.onFocusChanged = newValue }
  }

  init(descriptor: TerminalLaunchDescriptor) {
    controller = TerminalController(
      config: descriptor.serverConfig,
      terminalKey: descriptor.terminalKey,
      cwd: descriptor.workingDirectory)
    hostIO = GhosttyHostIO.make(for: controller)
    var config = Ghostty.SurfaceConfiguration()
    config.hostIO = hostIO.surfaceIO
    config.waitAfterCommand = true

    let view = CodevisorGhosttySurfaceView(CodevisorGhosttyApp.shared.app, baseConfig: config)
    if view.error != nil {
      Ghostty.logger.error(
        "terminal surface creation failed for \(descriptor.terminalKey, privacy: .public)")
      ErrorReporter.shared.report(
        .terminalOpenFailed,
        title: "Couldn't Open the Terminal",
        message: "Try closing and reopening the pane."
      )
    }
    view.focusDidChange(false)
    CodevisorGhosttyApp.shared.register(view)
    surfaceView = view

    let renderer = GhosttySurfaceRenderer(surface: view.surface, view: view)
    self.renderer = renderer
    controller.onError = { [weak renderer] message in
      renderer?.writeLive(Array("\r\n\u{1B}[2m[codevisor] \(message)\u{1B}[0m\r\n".utf8))
    }
    controller.attach(renderer)
    view.onClear = { [weak controller] in controller?.clear() }
    view.onUse = { [weak controller] in controller?.focus() }
    view.onUserInput = { [weak controller] in controller?.noteUserInput() }

    view.$pointerStyle
      .combineLatest(view.$mouseOverSurface)
      .sink { style, over in
        if over {
          style.cursor.set()
        } else {
          NSCursor.arrow.set()
        }
      }
      .store(in: &cancellables)
  }

  func setFocused(_ focused: Bool) {
    guard let surfaceView else { return }
    if focused {
      surfaceView.focusForInput()
    } else {
      surfaceView.focusDidChange(false)
      surfaceView.onFocusChanged?(false)
    }
  }

  func setVisible(_ visible: Bool) {
    controller.setVisible(visible)
  }

  func terminate() {
    controller.detach()
    let view = surfaceView
    if let view {
      CodevisorGhosttyApp.shared.unregister(view)
      view.removeFromSuperview()
    }
    cancellables.removeAll()
    surfaceView = nil
    renderer?.retire {
      withExtendedLifetime(view) {}
    }
  }
}

@MainActor
struct GhosttyTerminalFactory: TerminalSurfaceFactory {
  static let shared = GhosttyTerminalFactory()
  func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface {
    GhosttyTerminalSurface(descriptor: descriptor)
  }
}
