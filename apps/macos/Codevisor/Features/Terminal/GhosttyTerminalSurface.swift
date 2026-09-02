//  Bridges the vendored Ghostty.SurfaceView (upstream Ghostty's full AppKit
//  surface: NSTextInputClient/IME, performKeyEquivalent, tracking areas,
//  clipboard, DPI handling) to Codevisor's TerminalSurface protocol.

import AppKit
import Combine
import GhosttyKit
import CodevisorCore
import os

/// Upstream sizes the libghostty surface only via `sizeDidChange`, called from
/// its SwiftUI wrapper (not vendored). Codevisor drives the view with Auto Layout
/// (TerminalSurfaceView pins it into a container), so forward frame changes —
/// and the initial attach, when the window's backing scale becomes available —
/// into `sizeDidChange` here.
@MainActor
private final class CodevisorGhosttySurfaceView: Ghostty.SurfaceView {
  /// Set by the adapter; fired from the context menu's "Restart Terminal".
  var onRestartRequest: (() -> Void)?
  /// Set by the adapter; fired for pane-group shortcuts while focused.
  var onPaneCommand: ((PaneGroupCommand) -> Void)?
  /// Set by the adapter; fired when this surface gains/loses keyboard
  /// focus (first responder).
  var onFocusChanged: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      onFocusChanged?(true)
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

  /// The size last forwarded into libghostty, plus a one-per-runloop-turn
  /// coalescer. A libghostty resize is a full screen/scrollback reflow and
  /// SIGWINCHes the proxy PTY (a JSON frame over the WebSocket, a
  /// `node-pty.resize` on the server) — and a split-divider drag delivers
  /// frame changes at pointer-event rate to every terminal in the branch,
  /// with SwiftUI layout often setting the same frame several times per
  /// pass. Coalescing defers the reflow by at most one runloop turn.
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
      // Read the frame at fire time so a burst of drag deltas resolves
      // to a single reflow at the latest geometry.
      self.lastForwardedSize = self.frame.size
      self.sizeDidChange(self.frame.size)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    // Synchronous on purpose: the backing scale can change with the same
    // frame size, and first attach must size the surface before it draws.
    lastForwardedSize = frame.size
    sizeDidChange(frame.size)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    focusForInput()
    super.mouseDown(with: event)
  }

  func focusForInput() {
    if window == nil {
      Ghostty.moveFocus(to: self)
      return
    }
    window?.makeFirstResponder(self)
  }

  /// Workspace shortcuts, captured only while this surface has keyboard
  /// focus. Everything else falls through to Ghostty's key handling. The guard is the actual
  /// first-responder relationship — not the published `focused` flag, which
  /// can go stale and would eat composer/menu key equivalents.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown, window?.firstResponder === self, let onPaneCommand,
      // ⌘J is claimed here rather than left to the menu command: the
      // SwiftUI focused-scene value backing it is not reliably published
      // while an AppKit view is first responder. ⌘W likewise closes the
      // selected tab while a pane is focused; with focus elsewhere the
      // window's normal ⌘W applies.
      let command = ShortcutCatalog.paneCommand(for: event, includingPanelToggle: true)
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

/// A terminal surface backed by the vendored upstream Ghostty surface view.
@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
  private var surfaceView: CodevisorGhosttySurfaceView?
  private var cancellables = Set<AnyCancellable>()

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
    var config = Ghostty.SurfaceConfiguration()
    config.workingDirectory = descriptor.workingDirectory.path
    // Ghostty spawns the codevisor-terminal-proxy (not a shell); the proxy
    // bridges to the PTY on the codevisor server for this session.
    config.command = descriptor.command
    config.waitAfterCommand = true

    let view = CodevisorGhosttySurfaceView(CodevisorGhosttyApp.shared.app, baseConfig: config)
    if view.error != nil {
      Ghostty.logger.error(
        "terminal surface creation failed for \(descriptor.workingDirectory.path, privacy: .public)")
      ErrorReporter.shared.report(
        .terminalOpenFailed,
        title: "Couldn't Open the Terminal",
        message: "Try closing and reopening the pane."
      )
    }
    // Upstream initializes SurfaceView.focused to true before the C surface
    // exists. Codevisor mounts the view later, so reset the surface to the real
    // unfocused state now; the next AppKit first-responder transition will
    // publish the matching true focus event to libghostty.
    view.focusDidChange(false)
    CodevisorGhosttyApp.shared.register(view)
    surfaceView = view

    // Upstream applies the surface's published pointer style from its
    // SwiftUI wrapper (not vendored); mirror that here.
    view.$pointerStyle
      .combineLatest(view.$mouseOverSurface)
      .sink { style, over in
        if over {
          style.cursor.set()
        } else {
          // Reset promptly on exit — otherwise the I-beam lingers
          // until something else happens to set a cursor.
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
      // visibilityChanged(false) can clear Ghostty's input focus
      // without an AppKit resignFirstResponder transition. Publish the
      // same loss here so the pane group cannot keep stale shortcut
      // hints after focus moves back to the main workspace.
      surfaceView.onFocusChanged?(false)
    }
  }

  func terminate() {
    guard let view = surfaceView else { return }
    CodevisorGhosttyApp.shared.unregister(view)
    view.removeFromSuperview()
    cancellables.removeAll()
    // Dropping the last reference releases Ghostty.Surface, whose deinit
    // frees the C surface (and its child proxy process) on the main actor.
    surfaceView = nil
  }
}

@MainActor
struct GhosttyTerminalFactory: TerminalSurfaceFactory {
  static let shared = GhosttyTerminalFactory()
  func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface {
    GhosttyTerminalSurface(descriptor: descriptor)
  }
}
