import CodevisorCore
import Combine
import SwiftTerm
import UIKit

/// One terminal's renderer and connection, kept alive while its pane is off
/// screen (see `TerminalSessionCache`). It stays attached to the server's PTY
/// the whole time, so output from the shell and from other clients keeps
/// arriving, and returning to the pane shows the terminal as it is now
/// without replaying its history.
///
/// While off screen it is a passive viewer: it doesn't answer the queries
/// apps send (a visible client does), and when it's shown again it asserts
/// its size, since another client may have resized the PTY meanwhile.
@MainActor
final class TerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
  @Published private(set) var status: String?
  /// The shell ended; a later visit starts a new one, as the server allows.
  private(set) var hasExited = false
  var onExit: (() -> Void)?

  let view = SessionTerminalView(frame: .zero)
  private let transport: TerminalTransport
  private var appliedColors: TerminalColors?
  /// Set while replayed history is parsed, when SwiftTerm's answers to the
  /// old queries in it must not reach the shell.
  private var isFeedingReplay = false
  private var observers: [NSObjectProtocol] = []
  /// In flight while a burst of size changes settles; see `sizeChanged`.
  private var pendingResize: Task<Void, Never>?

  var isVisible: Bool { view.window != nil }

  init(terminalKey: String, cwd: String, config: CodevisorServerConfig, attachOnly: Bool) {
    var events: ((TerminalEvent) -> Void)?
    transport = TerminalTransport(config: config) { events?($0) }
    super.init()
    events = { [weak self] in self?.handle($0) }

    let fonts = TerminalFont.make()
    view.setFonts(
      normal: fonts.normal, bold: fonts.bold, italic: fonts.italic, boldItalic: fonts.boldItalic)
    // Colors 16–255 are the standard xterm cube and grays, as in Ghostty:
    // SwiftTerm otherwise derives them from the base sixteen, so apps that
    // pick a 256-color index get muted blends instead of the color asked for.
    view.getTerminal().ansi256PaletteStrategy = .xterm
    // Drop SwiftTerm's built-in TerminalAccessory: the key bar is a SwiftUI
    // Liquid Glass bar (TerminalKeyBar) just below the terminal, so the
    // keyboard gets no accessory strip (and no system backdrop behind one).
    view.inputAccessoryView = nil
    // Swipe down over the terminal to dismiss the keyboard.
    view.keyboardDismissMode = .interactive
    // The terminal renders in draw(_:), and UIView's default .scaleToFill
    // leaves the last frame it drew scaled across the new bounds until the
    // next display pass. Redraw at the new size instead.
    view.contentMode = .redraw
    view.terminalDelegate = self
    view.onShown = { [weak self] in self?.assertSize() }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // Another client may have resized the PTY while the app was away.
        MainActor.assumeIsolated {
          guard let self, self.isVisible else { return }
          self.assertSize()
        }
      })

    let terminal = view.getTerminal()
    let cols = max(2, terminal.cols)
    let rows = max(2, terminal.rows)
    Task { [weak self, transport] in
      do {
        try await transport.open(
          sessionId: terminalKey, cwd: cwd, cols: cols, rows: rows, attachOnly: attachOnly)
        self?.status = nil
      } catch {
        self?.status = "Couldn't open \(config.baseURL.absoluteString): \(error.localizedDescription)"
      }
    }
  }

  /// Leaves the PTY running server-side; only drops this renderer's socket.
  func detach() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    pendingResize?.cancel()
    pendingResize = nil
    transport.detach()
    view.removeFromSuperview()
  }

  /// SwiftTerm resolves its colors when they're set, so a change of
  /// appearance or theme applies them again.
  func apply(_ colors: TerminalColors) {
    guard colors != appliedColors else { return }
    appliedColors = colors
    view.backgroundColor = colors.background
    view.nativeBackgroundColor = colors.background
    view.nativeForegroundColor = colors.foreground
    view.caretColor = colors.cursor
    if let selection = colors.selection { view.selectedTextBackgroundColor = selection }
    if let ansi = colors.terminalANSI { view.installColors(ansi) }
    view.keyboardAppearance = colors.isDark ? .dark : .light
  }

  /// The PTY has one size, set by whichever client resized it last; the
  /// client being looked at claims it. An unchanged size is a no-op for the
  /// shell, so this is safe to repeat.
  private func assertSize() {
    let terminal = view.getTerminal()
    sendResize(cols: terminal.cols, rows: terminal.rows)
  }

  private func sendResize(cols: Int, rows: Int) {
    pendingResize?.cancel()
    pendingResize = nil
    transport.sendResize(cols: cols, rows: rows)
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case let .output(data, replayed):
      isFeedingReplay = replayed
      view.feed(text: data)
      isFeedingReplay = false
    case let .exit(code):
      hasExited = true
      status = "Shell exited\(code.map { " (\($0))" } ?? "")"
      onExit?()
    case let .error(message):
      status = message
    }
  }

  // MARK: - TerminalViewDelegate

  /// SwiftTerm calls this on the main thread, both for keystrokes and,
  /// synchronously inside `feed`, for replies to queries in the output.
  /// Replies are only sent live and on screen: a hidden terminal answering
  /// too would give an app two replies, one of which lands as input.
  nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
    let text = String(decoding: data, as: UTF8.self)
    MainActor.assumeIsolated {
      guard !isFeedingReplay, isVisible else { return }
      transport.sendInput(text)
    }
  }

  /// Every resize is a SIGWINCH that makes a full-screen app redraw, so a
  /// resize that is still moving — a rotation, a Stage Manager drag — sends
  /// only the size it settles at.
  nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
    MainActor.assumeIsolated {
      pendingResize?.cancel()
      pendingResize = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, let self else { return }
        self.pendingResize = nil
        self.transport.sendResize(cols: newCols, rows: newRows)
      }
    }
  }

  nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
  nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
  nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
  nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
    Task { @MainActor in
      if let url = URL(string: link) {
        UIApplication.shared.open(url)
      }
    }
  }
  nonisolated func bell(source: SwiftTerm.TerminalView) {}
  nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
    Task { @MainActor in
      if let text = String(data: content, encoding: .utf8) {
        UIPasteboard.general.string = text
      }
    }
  }
  nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// Reports each time the terminal is put back on screen, once it has been
/// laid out there, so the size it asserts is the one it will show at.
final class SessionTerminalView: SwiftTerm.TerminalView {
  var onShown: (() -> Void)?
  private var isAwaitingShownLayout = false

  override func didMoveToWindow() {
    super.didMoveToWindow()
    isAwaitingShownLayout = window != nil
    if isAwaitingShownLayout { setNeedsLayout() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard isAwaitingShownLayout, !bounds.isEmpty else { return }
    isAwaitingShownLayout = false
    onShown?()
  }
}

/// Keeps recent terminals alive across pane switches, bounded so hidden
/// terminals don't accumulate sockets and scrollback.
@MainActor
final class TerminalSessionCache {
  static let shared = TerminalSessionCache()

  struct Key: Hashable {
    let server: String
    let terminalKey: String
    let attachOnly: Bool
  }

  private static let budget = 8
  private var sessions: [Key: TerminalSession] = [:]
  /// Least recently shown first.
  private var order: [Key] = []
  private var memoryWarning: NSObjectProtocol?

  private init() {
    memoryWarning = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.evictHidden() }
    }
  }

  func session(
    terminalKey: String, cwd: String, config: CodevisorServerConfig, attachOnly: Bool
  ) -> TerminalSession {
    let key = Key(server: config.baseURL.absoluteString, terminalKey: terminalKey, attachOnly: attachOnly)
    // An ended shell stays up while it's on screen, showing its exit; the
    // next visit starts a new one.
    if let existing = sessions[key], !existing.hasExited || existing.isVisible {
      touch(key)
      return existing
    }
    evict(key)
    let session = TerminalSession(
      terminalKey: terminalKey, cwd: cwd, config: config, attachOnly: attachOnly)
    session.onExit = { [weak self, weak session] in
      guard let session, !session.isVisible else { return }
      self?.evict(key)
    }
    sessions[key] = session
    touch(key)
    while order.count > Self.budget, let oldest = order.first(where: { sessions[$0]?.isVisible == false }) {
      evict(oldest)
    }
    return session
  }

  /// The pane left the screen: an ended shell has nothing more to show.
  func didHide(_ session: TerminalSession) {
    guard session.hasExited, let key = sessions.first(where: { $0.value === session })?.key else { return }
    evict(key)
  }

  /// The terminal's tab was closed on this device.
  func remove(terminalKey: String) {
    for key in sessions.keys where key.terminalKey == terminalKey { evict(key) }
  }

  private func evictHidden() {
    for (key, session) in sessions where !session.isVisible { evict(key) }
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func evict(_ key: Key) {
    order.removeAll { $0 == key }
    sessions.removeValue(forKey: key)?.detach()
  }
}
