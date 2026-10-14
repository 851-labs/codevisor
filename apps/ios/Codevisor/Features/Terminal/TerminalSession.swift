import CodevisorCore
import Combine
import GhosttyTerminal
import UIKit

@MainActor
final class TerminalSession: NSObject, ObservableObject {
  @Published private(set) var status: String?
  private(set) var hasExited = false
  var onExit: (() -> Void)?

  let view = SessionTerminalView(frame: .zero)
  private let connection: CodevisorCore.TerminalController
  private let session: InMemoryTerminalSession
  private let renderer: SessionRenderer
  private var appliedColors: TerminalColors?
  private var observers: [NSObjectProtocol] = []
  private var surfaceSize: (cols: Int, rows: Int)?
  private var surfaceSizeMeasuredAt: CGSize?
  private var pendingFollow: Task<Void, Never>?
  private var pendingResize: Task<Void, Never>?
  private var surfaceGrid: (cols: Int, rows: Int)?
  private var shownPTYSize: (cols: Int, rows: Int)?
  private var gridTimeout: Task<Void, Never>?

  var isVisible: Bool { view.window != nil }

  init(terminalKey: String, cwd: String, config: CodevisorServerConfig) {
    connection = CodevisorCore.TerminalController(
      config: config, terminalKey: terminalKey, cwd: cwd)
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

    view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    view.onShown = { [weak self] in self?.claim() }
    view.onUse = { [weak self] in self?.connection.focus() }
    view.onUserInput = { [weak self] in self?.connection.noteUserInput() }
    view.onClear = { [weak self] in self?.connection.clear() }
    view.foreignGrid = { [weak self] available in self?.foreignGrid(for: available) }
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
        MainActor.assumeIsolated {
          guard let self, self.isVisible else { return }
          self.claim()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.hide() }
      })
  }

  func reconnect() {
    guard !hasExited else { return }
    connection.reconnect()
  }

  func hide() {
    pendingResize?.cancel()
    pendingResize = nil
    connection.setVisible(false)
  }

  func detach() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    pendingResize?.cancel()
    pendingResize = nil
    connection.detach()
    view.removeFromSuperview()
  }

  func apply(_ colors: TerminalColors) {
    guard colors != appliedColors else { return }
    appliedColors = colors
    view.backgroundColor = colors.background
    let configuration = colors.ghosttyConfiguration(fontSize: Float(TerminalFont.size))
    if let controller = view.controller {
      controller.setTerminalConfiguration(configuration)
    } else {
      view.controller = GhosttyTerminal.TerminalController(
        configuration: configuration, theme: TerminalTheme())
    }
  }

  private func claim() {
    if let surfaceSize {
      pendingResize?.cancel()
      pendingResize = nil
      connection.resize(cols: surfaceSize.cols, rows: surfaceSize.rows)
    }
    connection.focus()
  }

  private func surfaceProduced(_ bytes: [UInt8]) {
    guard isVisible else { return }
    connection.produced(bytes)
  }

  private func surfaceResized(cols: Int, rows: Int) {
    surfaceGrid = (cols, rows)
    if let awaiting = renderer.awaitedColumns, cols >= awaiting {
      gridTimeout?.cancel()
      renderer.stopWaiting()
    }
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
  fileprivate func outputWritten() {
    guard view.showsForeignGrid, pendingFollow == nil else { return }
    pendingFollow = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(60))
      guard let self else { return }
      self.pendingFollow = nil
      self.view.superview?.setNeedsLayout()
    }
  }

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

  fileprivate func foreignGrid(for available: CGSize) -> CGSize? {
    guard let pty = shownPTYSize, let own = surfaceSize,
      let measuredAt = surfaceSizeMeasuredAt, own.cols > 0, own.rows > 0,
      measuredAt.width > 0, measuredAt.height > 0, available.width > 0, available.height > 0,
      (pty.cols, pty.rows) != (own.cols, own.rows)
    else { return nil }
    let cell = CGSize(
      width: measuredAt.width / CGFloat(own.cols), height: measuredAt.height / CGFloat(own.rows))
    let columns = available.width / cell.width
    let rows = available.height / cell.height
    let wider = CGFloat(pty.cols) > columns + 0.5
    guard wider || (!connection.claimsSize && CGFloat(pty.rows) > rows + 0.5) else { return nil }
    return CGSize(
      width: CGFloat(pty.cols) * cell.width * 1.02, height: CGFloat(pty.rows) * cell.height * 1.02)
  }
}

@MainActor
private final class WeakSession {
  weak var value: TerminalSession?
}

@MainActor
private final class SessionRenderer: TerminalRenderer {
  private let session: InMemoryTerminalSession
  var onPrediction: ((EchoPredictor.Overlay?) -> Void)?
  private let startedAt = ContinuousClock.now

  init(session: InMemoryTerminalSession) {
    self.session = session
  }

  private enum Step {
    case output([UInt8], replay: Bool)
    case size(cols: Int, rows: Int)
  }
  private var steps: [Step] = []
  private(set) var awaitedColumns: Int?
  var showSize: ((_ cols: Int, _ rows: Int) -> Int?)?
  var onWrite: (() -> Void)?

  func ptyResized(cols: Int, rows: Int) { run(.size(cols: cols, rows: rows)) }
  func writeLive(_ bytes: [UInt8]) { run(.output(bytes, replay: false)) }
  func writeReplay(_ bytes: [UInt8]) { run(.output(bytes, replay: true)) }

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

final class SessionTerminalView: GhosttyTerminal.TerminalView {
  var onShown: (() -> Void)?
  var onClear: (() -> Void)?
  var onUse: (() -> Void)?
  var foreignGrid: ((CGSize) -> CGSize?)?
  var showsForeignGrid = false {
    didSet { if !showsForeignGrid { followedCursor = nil } }
  }
  var appliedScale: CGFloat = 1
  var zoom: CGFloat = 1
  var panOffset: CGPoint = .zero
  private var followedCursor: CGPoint?

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onUse?() }
    return became
  }

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

  func showPrediction(_ overlay: EchoPredictor.Overlay?) {
    guard let overlay, let cell = cursorCell() else {
      predictionLabel?.removeFromSuperview()
      predictionLabel = nil
      return
    }
    let label = predictionLabel ?? UILabel()
    if label.superview !== self { addSubview(label) }
    predictionLabel = label
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
