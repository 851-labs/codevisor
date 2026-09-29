import CodevisorCore
import Combine
import GhosttyTerminal
import UIKit

/// One terminal's renderer and connection, kept alive while its pane is off
/// screen (see `TerminalSessionCache`). It stays attached to the server's PTY
/// the whole time, so output from the shell and from other clients keeps
/// arriving, and returning to the pane shows the terminal as it is now
/// without replaying its history.
///
/// The renderer is libghostty (the vendored GhosttyTerminal view) in
/// host-managed I/O mode: no local process runs behind it. The shared
/// `CodevisorCore.TerminalController` streams the server PTY into the
/// surface — history through the replay path, so queries in it aren't
/// answered again — and the surface's input and size go back to the server.
///
/// While off screen it is a passive viewer: it doesn't answer the queries
/// apps send (a visible client does), and when it's shown again it asserts
/// its size, since another client may have resized the PTY meanwhile.
@MainActor
final class TerminalSession: NSObject, ObservableObject {
  @Published private(set) var status: String?
  /// The shell ended; a later visit starts a new one, as the server allows.
  private(set) var hasExited = false
  var onExit: (() -> Void)?

  let view = SessionTerminalView(frame: .zero)
  private let connection: CodevisorCore.TerminalController
  private let session: InMemoryTerminalSession
  private let renderer: SessionRenderer
  private var appliedColors: TerminalColors?
  private var observers: [NSObjectProtocol] = []
  /// The grid the surface last reported at this device's own scale — what
  /// this device asks the PTY to be — re-asserted when shown.
  private var surfaceSize: (cols: Int, rows: Int)?
  /// The view size that grid was measured at, to estimate this device's grid
  /// at other sizes while it shows a larger PTY scaled down.
  private var surfaceSizeMeasuredAt: CGSize?
  /// Brings the cursor on screen once a burst of output is parsed.
  private var pendingFollow: Task<Void, Never>?
  /// In flight while a burst of size changes settles; see `surfaceResized`.
  private var pendingResize: Task<Void, Never>?
  /// The grid the surface has now, at whatever scale it is laid out.
  private var surfaceGrid: (cols: Int, rows: Int)?
  /// The PTY size the terminal is laid out for: the latest the stream has
  /// reached, which the output after it was written for.
  private var shownPTYSize: (cols: Int, rows: Int)?
  /// Stops waiting for a wider grid if the surface never reports it.
  private var gridTimeout: Task<Void, Never>?

  var isVisible: Bool { view.window != nil }

  init(terminalKey: String, cwd: String, config: CodevisorServerConfig, attachOnly: Bool) {
    connection = CodevisorCore.TerminalController(
      config: config, terminalKey: terminalKey, cwd: cwd, attachOnly: attachOnly)
    // libghostty calls these on its I/O thread; the main queue keeps their
    // order.
    let owner = WeakSession()
    session = InMemoryTerminalSession(
      write: { data in
        let bytes = [UInt8](data)
        DispatchQueue.main.async { MainActor.assumeIsolated { owner.value?.surfaceProduced(bytes) } }
      },
      resize: { viewport in
        let cols = Int(viewport.columns)
        let rows = Int(viewport.rows)
        DispatchQueue.main.async {
          MainActor.assumeIsolated { owner.value?.surfaceResized(cols: cols, rows: rows) }
        }
      },
      suppressesPixelOnlyResizes: true)
    renderer = SessionRenderer(session: session)
    super.init()
    renderer.onWrite = { [weak self] in self?.outputWritten() }
    owner.value = self
    renderer.onPrediction = { [weak self] overlay in self?.view.showPrediction(overlay) }

    // The key bar is a SwiftUI Liquid Glass bar (TerminalKeyBar) just below
    // the terminal, so the view's own accessory strip is suppressed (see
    // SessionTerminalView).
    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    // Opening the terminal here, tapping into it, or bringing the app back
    // with it on screen makes this the device being used: the PTY takes its
    // size (and another device's use takes it back).
    view.onShown = { [weak self] in self?.claim() }
    view.onUse = { [weak self] in self?.connection.focus() }
    view.onUserInput = { [weak self] in self?.connection.noteUserInput() }
    view.onClear = { [weak self] in self?.connection.clear() }
    view.foreignGrid = { [weak self] available in self?.foreignGrid(for: available) }
    // The PTY's size changed (another device is being used) or was announced
    // on attach: lay the terminal out now, at the PTY's grid if it's another
    // device's, before the output that follows is parsed at the old grid.
    connection.onPTYSize = { [weak self] cols, rows in self?.renderer.ptyResized(cols: cols, rows: rows) }
    renderer.showSize = { [weak self] cols, rows in self?.show(ptyCols: cols, rows: rows) }
    connection.onExit = { [weak self] in
      guard let self else { return }
      self.hasExited = true
      self.status = "Shell exited\(self.connection.exitCode.map { " (\($0))" } ?? "")"
      self.onExit?()
    }
    connection.onError = { [weak self] message in self?.status = message }
    connection.attach(renderer)
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // Another client may have resized the PTY while the app was away.
        MainActor.assumeIsolated {
          guard let self, self.isVisible else { return }
          self.claim()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // Off screen: stop constraining the PTY's size for other devices.
        MainActor.assumeIsolated { self?.hide() }
      })
  }

  /// The app came back to the foreground or changed networks: the socket may
  /// be half-open, so replace it now instead of waiting for it to time out.
  func reconnect() {
    guard !hasExited else { return }
    connection.reconnect()
  }

  /// The pane went off screen (or the app to the background): the PTY is
  /// sized for the devices still showing it.
  func hide() {
    pendingResize?.cancel()
    pendingResize = nil
    connection.setVisible(false)
  }

  /// Leaves the PTY running server-side; only drops this renderer's socket.
  func detach() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    pendingResize?.cancel()
    pendingResize = nil
    connection.detach()
    view.removeFromSuperview()
  }

  /// A change of appearance or theme reconfigures the surface in place.
  func apply(_ colors: TerminalColors) {
    guard colors != appliedColors else { return }
    appliedColors = colors
    view.backgroundColor = colors.background
    let configuration = colors.ghosttyConfiguration(fontSize: Float(TerminalFont.size))
    if let controller = view.controller {
      controller.setTerminalConfiguration(configuration)
    } else {
      // An empty theme: the controller's default (the vendored package's
      // Afterglow/Alabaster themes) would otherwise be layered over these
      // colors.
      view.controller = GhosttyTerminal.TerminalController(
        configuration: configuration, theme: TerminalTheme())
    }
  }

  /// Shown here: this device's size goes to the server again, and the PTY
  /// takes it, since the device being looked at is the one being used. An
  /// unchanged size is a no-op for the shell, so this is safe to repeat.
  private func claim() {
    if let surfaceSize {
      pendingResize?.cancel()
      pendingResize = nil
      connection.resize(cols: surfaceSize.cols, rows: surfaceSize.rows)
    }
    connection.focus()
  }

  /// Keystrokes, pastes, and the surface's replies to queries in live
  /// output. Replies are only sent on screen: a hidden terminal answering
  /// too would give an app two replies, one of which lands as input.
  private func surfaceProduced(_ bytes: [UInt8]) {
    guard isVisible else { return }
    connection.produced(bytes)
  }

  /// The first size opens the server terminal. After that, every resize is
  /// a SIGWINCH that makes a full-screen app redraw, so a resize that is
  /// still moving — a rotation, a Stage Manager drag — sends only the size
  /// it settles at.
  private func surfaceResized(cols: Int, rows: Int) {
    surfaceGrid = (cols, rows)
    if let awaiting = renderer.awaitedColumns, cols >= awaiting {
      gridTimeout?.cancel()
      renderer.stopWaiting()
    }
    // Showing another device's grid, the surface's size is that device's,
    // not this one's: nothing to ask for.
    guard !view.showsForeignGrid else { return }
    surfaceSizeMeasuredAt = view.bounds.size
    let first = surfaceSize == nil
    surfaceSize = (cols, rows)
    if first {
      connection.start(cols: cols, rows: rows)
      return
    }
    pendingResize?.cancel()
    pendingResize = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(50))
      guard !Task.isCancelled, let self else { return }
      self.pendingResize = nil
      self.connection.resize(cols: cols, rows: rows)
    }
  }
}

extension TerminalSession {
  /// Showing another device's grid cropped, the view follows the cursor as
  /// output moves it, once libghostty (asynchronously) has parsed it.
  fileprivate func outputWritten() {
    guard view.showsForeignGrid, pendingFollow == nil else { return }
    pendingFollow = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(60))
      guard let self else { return }
      self.pendingFollow = nil
      self.view.superview?.setNeedsLayout()
    }
  }

  /// Lays the terminal out for a PTY size the stream reached. libghostty
  /// applies a new size on its I/O thread a little later, but parses output
  /// as soon as it's written: output for a wider PTY parsed before then
  /// would wrap at the old, narrower grid and stay wrapped (zsh's
  /// end-of-line mark would show as a stray `%`). So when the grid has to
  /// widen, returns the columns the output after this must wait for (or a
  /// moment, if the surface never reports them).
  fileprivate func show(ptyCols cols: Int, rows: Int) -> Int? {
    shownPTYSize = (cols, rows)
    guard let container = view.superview else { return nil }
    container.setNeedsLayout()
    container.layoutIfNeeded()
    guard view.showsForeignGrid, let grid = surfaceGrid, grid.cols < cols else { return nil }
    gridTimeout?.cancel()
    gridTimeout = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      self?.renderer.stopWaiting()
    }
    return cols
  }

  /// While another device owns the PTY at a size this one can't show at its
  /// own grid, this device shows that exact grid (in points, at scale 1)
  /// rather than reflowing it into a smaller one, which would wrap every
  /// full-width line: prompts, TUIs. The container crops it to the screen
  /// at a readable size, following the cursor; it can be panned, and
  /// pinched out to see all of it. nil when this device's own grid fits.
  ///
  /// Also while this device's claim is on its way: output until the server
  /// applies it is still laid out for the wider grid, and parsed at this
  /// device's narrower one it would wrap and stay wrapped. Only a narrower
  /// grid counts then — fewer rows (the keyboard coming up) wrap nothing.
  fileprivate func foreignGrid(for available: CGSize) -> CGSize? {
    guard let pty = shownPTYSize, let own = surfaceSize,
      let measuredAt = surfaceSizeMeasuredAt, own.cols > 0, own.rows > 0,
      measuredAt.width > 0, measuredAt.height > 0, available.width > 0, available.height > 0,
      (pty.cols, pty.rows) != (own.cols, own.rows)
    else { return nil }
    let cell = CGSize(
      width: measuredAt.width / CGFloat(own.cols), height: measuredAt.height / CGFloat(own.rows))
    // This device's own grid at the available size.
    let columns = available.width / cell.width
    let rows = available.height / cell.height
    let wider = CGFloat(pty.cols) > columns + 0.5
    guard wider || (!connection.claimsSize && CGFloat(pty.rows) > rows + 0.5) else { return nil }
    // A little over, so rounding never leaves it a column or row short.
    return CGSize(
      width: CGFloat(pty.cols) * cell.width * 1.02, height: CGFloat(pty.rows) * cell.height * 1.02)
  }
}

/// Lets libghostty's callbacks reach their session without a cycle.
@MainActor
private final class WeakSession {
  weak var value: TerminalSession?
}

/// Writes the server's stream into the in-memory session behind the view.
@MainActor
private final class SessionRenderer: TerminalRenderer {
  private let session: InMemoryTerminalSession
  var onPrediction: ((EchoPredictor.Overlay?) -> Void)?
  /// Ghostty reports an exit with (near) zero runtime as a failed launch.
  private let startedAt = ContinuousClock.now

  init(session: InMemoryTerminalSession) {
    self.session = session
  }

  /// The stream in order: output, and the PTY size changes the output
  /// after them was written for.
  private enum Step {
    case output([UInt8], replay: Bool)
    case size(cols: Int, rows: Int)
  }
  private var steps: [Step] = []
  /// Set while output waits for the surface to reach this many columns.
  private(set) var awaitedColumns: Int?
  /// Lays the terminal out for a PTY size; returns the columns the surface
  /// must reach before later output can be parsed, if it isn't there yet.
  var showSize: ((_ cols: Int, _ rows: Int) -> Int?)?
  var onWrite: (() -> Void)?

  func ptyResized(cols: Int, rows: Int) { run(.size(cols: cols, rows: rows)) }
  func writeLive(_ bytes: [UInt8]) { run(.output(bytes, replay: false)) }
  func writeReplay(_ bytes: [UInt8]) { run(.output(bytes, replay: true)) }

  /// The surface reached the awaited grid, or it's taking too long.
  func stopWaiting() {
    awaitedColumns = nil
    drain()
  }

  private func run(_ step: Step) {
    steps.append(step)
    drain()
  }

  private func drain() {
    while awaitedColumns == nil, !steps.isEmpty {
      switch steps.removeFirst() {
      case let .output(bytes, replay):
        if replay {
          session.receiveReplay(Data(bytes))
        } else {
          session.receive(Data(bytes))
        }
        onWrite?()
      case let .size(cols, rows):
        awaitedColumns = showSize?(cols, rows)
      }
    }
  }

  func showPrediction(_ overlay: EchoPredictor.Overlay?) { onPrediction?(overlay) }
  func processExited(code: Int?) {
    let runtime = TerminalTransport.milliseconds(startedAt.duration(to: .now))
    session.finish(
      exitCode: UInt32(truncatingIfNeeded: code ?? 0), runtimeMilliseconds: UInt64(max(0, runtime)))
  }
}

/// The Ghostty terminal view without its built-in accessory strip, reporting
/// each time it is put back on screen once it has been laid out there, so
/// the size it asserts is the one it will show at.
final class SessionTerminalView: GhosttyTerminal.TerminalView {
  var onShown: (() -> Void)?
  /// ⌘K on a hardware keyboard: clear the terminal for every device.
  var onClear: (() -> Void)?
  /// The terminal was tapped or focused here: it takes the PTY's size.
  var onUse: (() -> Void)?
  /// Another device's grid to show instead of this one's own, if any (see
  /// `TerminalSession.foreignGrid`).
  var foreignGrid: ((CGSize) -> CGSize?)?
  /// Laid out at another device's grid rather than its own.
  var showsForeignGrid = false {
    didSet { if !showsForeignGrid { followedCursor = nil } }
  }
  /// The scale it is laid out at now.
  var appliedScale: CGFloat = 1
  /// The scale chosen by pinching another device's grid, clamped between
  /// fitting all of it and 1.
  var zoom: CGFloat = 1
  /// How far another device's grid is panned, in on-screen points.
  var panOffset: CGPoint = .zero
  private var followedCursor: CGPoint?

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onUse?() }
    return became
  }

  /// A key press, typed text, a touch or a paste: what the surface produces
  /// next is the user's, not a reply to a program's query.
  var onUserInput: (() -> Void)?
  func noteUserInput() { onUserInput?() }

  override func insertText(_ text: String) {
    noteUserInput()
    super.insertText(text)
  }

  override func deleteBackward() {
    noteUserInput()
    super.deleteBackward()
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    noteUserInput()
    super.pressesBegan(presses, with: event)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    noteUserInput()
    super.touchesBegan(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    noteUserInput()
    super.touchesEnded(touches, with: event)
  }

  override func paste(_ sender: Any?) {
    noteUserInput()
    super.paste(sender)
  }

  /// The cursor's cell (in this view's own coordinates) if it moved since
  /// the view last followed it: a pan stays put until output moves it.
  func cursorToFollow() -> CGRect? {
    guard let cell = cursorCell() else { return nil }
    guard cell.origin != followedCursor else { return nil }
    followedCursor = cell.origin
    return cell
  }

  override var keyCommands: [UIKeyCommand]? {
    let clear = UIKeyCommand(
      title: "Clear", action: #selector(clearTerminal), input: "k", modifierFlags: .command)
    clear.wantsPriorityOverSystemBehavior = true
    return (super.keyCommands ?? []) + [clear]
  }

  @objc private func clearTerminal() {
    onClear?()
  }
  private var isAwaitingShownLayout = false

  override var inputAccessoryView: UIView? { nil }

  private var predictionLabel: UILabel?

  /// Local echo on slow links, drawn over the cursor cell until the
  /// server's echo replaces it.
  func showPrediction(_ overlay: EchoPredictor.Overlay?) {
    guard let overlay, let cell = cursorCell() else {
      predictionLabel?.removeFromSuperview()
      predictionLabel = nil
      return
    }
    let label = predictionLabel ?? UILabel()
    if label.superview !== self { addSubview(label) }
    predictionLabel = label
    // JetBrains Mono (Ghostty's default) advances 0.6em per character.
    let size = cell.width / 0.6
    let font =
      UIFont(name: "JetBrainsMono-Regular", size: size)
      ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    label.attributedText = NSAttributedString(
      string: overlay.text,
      attributes: [
        .font: font,
        .foregroundColor: UIColor.label.withAlphaComponent(0.7),
        .underlineStyle: overlay.underlined ? NSUnderlineStyle.single.rawValue : 0,
      ])
    label.frame = CGRect(
      x: cell.minX, y: cell.minY,
      width: cell.width * Double(overlay.text.count) + 2, height: cell.height)
  }

  /// The cursor's cell, in this view's own coordinates. Ghostty reports the
  /// middle of its bottom edge.
  private func cursorCell() -> CGRect? {
    guard let surface, let pixels = surface.cellPixelSize() else { return nil }
    let point = surface.imePoint()
    let width = pixels.width / traitCollection.displayScale
    guard width > 0, point.height > 0 else { return nil }
    return CGRect(x: point.x - width / 2, y: point.y - point.height, width: width, height: point.height)
  }

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
