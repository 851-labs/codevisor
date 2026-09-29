import Foundation

/// What a terminal emulator view does with the server's stream. Both apps
/// back this with a libghostty surface in host-managed I/O mode.
@MainActor
public protocol TerminalRenderer: AnyObject {
  /// Live PTY output: parse it and answer any queries it contains.
  func writeLive(_ bytes: [UInt8])
  /// History (replayed output, or the server's reconstruction of the screen):
  /// parse it, but don't answer its queries — the program asked them long
  /// ago, and the replies would land as input in whatever runs now.
  func writeReplay(_ bytes: [UInt8])
  /// The shell ended.
  func processExited(code: Int?)
  /// Local echo to draw over the cursor until the server's echo arrives
  /// (nil: none). Only on slow links; see EchoPredictor.
  func showPrediction(_ overlay: EchoPredictor.Overlay?)
}

extension TerminalRenderer {
  public func showPrediction(_ overlay: EchoPredictor.Overlay?) {}
}

/// One terminal pane's connection to a server-side PTY, independent of the
/// view that renders it: opens the transport, orders its output into the
/// renderer (holding it until a renderer attaches), and forwards the
/// renderer's input and size back. The Ghostty surface callbacks that feed
/// `input(_:)` and `resize(cols:rows:)` run on libghostty's I/O thread;
/// callers hop to the main actor first, which keeps their order.
@MainActor
public final class TerminalController {
  public private(set) var hasExited = false
  public private(set) var exitCode: Int?
  /// The latest error the server reported, for display.
  public private(set) var lastError: String?
  public var onExit: (() -> Void)?
  /// The PTY's current size (the client being typed on sets it), once the
  /// server has said.
  public private(set) var ptySize: (cols: Int, rows: Int)?
  public var onPTYSize: ((_ cols: Int, _ rows: Int) -> Void)?
  public var onError: ((String) -> Void)?

  private let terminalKey: String
  private let cwd: String
  private let attachOnly: Bool
  private let transport: TerminalTransport
  private weak var renderer: (any TerminalRenderer)?
  /// Output that arrived before a renderer attached, in order.
  private var pending: [(bytes: [UInt8], replayed: Bool)] = []
  private var opened = false
  /// The size this client last asked the PTY to be.
  private var ownSize: (cols: Int, rows: Int)?
  /// When the user last pressed a key, clicked, touched or pasted here.
  private var lastUserInput: ContinuousClock.Instant?
  /// What the renderer produces this soon after the user acted is theirs.
  static let userInputWindow: Duration = .milliseconds(500)
  private var predictor = EchoPredictor()
  private var shownPrediction: EchoPredictor.Overlay?
  /// Ages pending predictions (underline, glitch) while there are any.
  private var predictionTicker: Task<Void, Never>?
  private let clock: @Sendable () -> ContinuousClock.Instant
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    config: CodevisorServerConfig,
    terminalKey: String,
    cwd: String,
    attachOnly: Bool = false,
    clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.clock = clock
    self.sleep = sleep
    self.terminalKey = terminalKey
    self.cwd = cwd
    self.attachOnly = attachOnly
    let owner = WeakController()
    transport = TerminalTransport(config: config) { event in owner.value?.handle(event) }
    owner.value = self
  }

  /// Smoothed round trip to the server, once measured.
  public var roundTripTime: Duration? { transport.roundTripTime }

  /// Creates or attaches to the server's terminal at the renderer's size.
  /// Idempotent: later calls only update the size.
  public func start(cols: Int, rows: Int) {
    ownSize = (cols, rows)
    guard !opened else {
      resize(cols: cols, rows: rows)
      return
    }
    opened = true
    transport.sendResize(cols: cols, rows: rows)
    Task { [weak self, transport, terminalKey, cwd, attachOnly] in
      do {
        try await transport.open(
          sessionId: terminalKey, cwd: cwd, cols: cols, rows: rows, attachOnly: attachOnly)
      } catch {
        self?.report(error.localizedDescription)
      }
    }
  }

  /// Attaches the view that renders this terminal, flushing held output.
  public func attach(_ renderer: any TerminalRenderer) {
    self.renderer = renderer
    let held = pending
    pending = []
    for chunk in held { deliver(chunk.bytes, replayed: chunk.replayed) }
    if hasExited { renderer.processExited(code: exitCode) }
  }

  /// The user pressed a key, clicked, touched or pasted in the renderer:
  /// what it produces next is theirs (see `produced(_:)`).
  public func noteUserInput() {
    lastUserInput = clock()
  }

  /// Whether this client answers the queries programs send (device
  /// attributes, cursor position…): the one whose size the PTY has, so a
  /// program hears one answer, from the screen it's laid out for.
  public var answersQueries: Bool {
    guard let ptySize, let ownSize else { return true }
    return transport.claimsSize || (ptySize.cols == ownSize.cols && ptySize.rows == ownSize.rows)
  }

  /// Bytes the renderer produced. Just after the user acted here they're
  /// keystrokes, a paste or mouse input, and this client is the one being
  /// used; otherwise they're the terminal's replies to a program's queries,
  /// which must not take the PTY's size — every client showing a program
  /// that queries would take it from the others on each redraw.
  public func produced(_ bytes: [UInt8]) {
    guard let lastUserInput, lastUserInput.duration(to: clock()) < Self.userInputWindow else {
      reply(bytes)
      return
    }
    input(bytes)
  }

  /// The terminal's replies to a program's queries, sent only by the client
  /// that answers them (`answersQueries`).
  public func reply(_ bytes: [UInt8]) {
    guard !hasExited, !bytes.isEmpty, answersQueries else { return }
    transport.sendReply(String(decoding: bytes, as: UTF8.self))
  }

  /// What the user typed or pasted: it goes to the program, and this client
  /// takes the PTY's size.
  public func input(_ bytes: [UInt8]) {
    guard !hasExited, !bytes.isEmpty else { return }
    let text = String(decoding: bytes, as: UTF8.self)
    predictor.roundTripChanged(transport.roundTripTime)
    predictor.typed(text, at: clock())
    publishPrediction()
    transport.sendInput(text)
  }

  public func resize(cols: Int, rows: Int) {
    guard cols > 0, rows > 0 else { return }
    ownSize = (cols, rows)
    transport.sendResize(cols: cols, rows: rows)
  }

  /// Whether this client owns the PTY's size: it was used here last.
  public var claimsSize: Bool { transport.claimsSize }

  /// The terminal was opened, tapped or clicked into on this client: the
  /// PTY takes this client's size, as when it's typed on.
  public func focus() {
    guard !hasExited else { return }
    transport.sendFocus()
  }

  /// ⌘K, for every client showing this terminal.
  public func clear() {
    guard !hasExited else { return }
    transport.sendClear()
  }

  /// The terminal went on or off screen. Only on-screen clients size the
  /// PTY (the smallest of them), so a hidden pane stops constraining it and
  /// a shown one claims its size again.
  public func setVisible(_ visible: Bool) {
    guard !hasExited else { return }
    if visible {
      transport.reassertSize()
    } else {
      transport.sendHidden()
    }
  }

  /// Replaces a possibly half-open socket (foreground, network change).
  public func reconnect() {
    guard !hasExited else { return }
    transport.reconnectNow()
  }

  /// Leaves the server's shell running (the pane may be shown again later).
  public func detach() {
    transport.detach()
  }

  /// Ends the server's shell.
  public func close() {
    transport.close()
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case let .output(text, replayed):
      deliver(Array(text.utf8), replayed: replayed)
    case let .exit(code):
      hasExited = true
      predictionTicker?.cancel()
      predictionTicker = nil
      if shownPrediction != nil {
        shownPrediction = nil
        renderer?.showPrediction(nil)
      }
      exitCode = code
      renderer?.processExited(code: code)
      onExit?()
    case let .error(message):
      report(message)
    case let .ptySize(cols, rows):
      ptySize = (cols, rows)
      onPTYSize?(cols, rows)
    }
  }

  private func deliver(_ bytes: [UInt8], replayed: Bool) {
    if !replayed {
      predictor.received(String(decoding: bytes, as: UTF8.self))
      publishPrediction()
    }
    guard let renderer else {
      pending.append((bytes, replayed))
      return
    }
    if replayed { renderer.writeReplay(bytes) } else { renderer.writeLive(bytes) }
  }

  private func publishPrediction() {
    let overlay = predictor.overlay(at: clock())
    if overlay != shownPrediction {
      shownPrediction = overlay
      renderer?.showPrediction(overlay)
    }
    if overlay == nil {
      predictionTicker?.cancel()
      predictionTicker = nil
    } else if predictionTicker == nil {
      predictionTicker = Task { [weak self, sleep] in
        while !Task.isCancelled {
          try? await sleep(.milliseconds(40))
          guard let self, !Task.isCancelled else { return }
          self.predictor.tick(at: self.clock())
          self.publishPrediction()
        }
      }
    }
  }

  private func report(_ message: String) {
    lastError = message
    onError?(message)
  }
}

/// Lets the transport's event handler reach its controller without a cycle.
@MainActor
private final class WeakController {
  weak var value: TerminalController?
}
