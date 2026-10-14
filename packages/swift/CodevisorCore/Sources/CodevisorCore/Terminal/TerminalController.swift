import Foundation

@MainActor
public protocol TerminalRenderer: AnyObject {
  func writeLive(_ bytes: [UInt8])
  func writeReplay(_ bytes: [UInt8])
  func processExited(code: Int?)
  func showPrediction(_ overlay: EchoPredictor.Overlay?)
}

extension TerminalRenderer {
  public func showPrediction(_ overlay: EchoPredictor.Overlay?) {}
}

@MainActor
public final class TerminalController {
  public private(set) var hasExited = false
  public private(set) var exitCode: Int?
  public private(set) var lastError: String?
  public var onExit: (() -> Void)?
  public private(set) var ptySize: (cols: Int, rows: Int)?
  public var onPTYSize: ((_ cols: Int, _ rows: Int) -> Void)?
  public var onError: ((String) -> Void)?

  private let terminalKey: String
  private let cwd: String
  private let transport: TerminalTransport
  private weak var renderer: (any TerminalRenderer)?
  private var pending: [(output: TerminalOutput, replayed: Bool)] = []
  private var opened = false
  private var ownSize: (cols: Int, rows: Int)?
  private var lastUserInput: ContinuousClock.Instant?
  static let userInputWindow: Duration = .milliseconds(500)
  private var predictor = EchoPredictor()
  private var shownPrediction: EchoPredictor.Overlay?
  private var predictionTicker: Task<Void, Never>?
  private let clock: @Sendable () -> ContinuousClock.Instant
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    config: CodevisorServerConfig,
    terminalKey: String,
    cwd: String,
    clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.clock = clock
    self.sleep = sleep
    self.terminalKey = terminalKey
    self.cwd = cwd
    let owner = WeakController()
    transport = TerminalTransport(config: config) { event in owner.value?.handle(event) }
    owner.value = self
  }

  public var roundTripTime: Duration? { transport.roundTripTime }

  public func start(cols: Int, rows: Int) {
    ownSize = (cols, rows)
    guard !opened else {
      resize(cols: cols, rows: rows)
      return
    }
    opened = true
    transport.sendResize(cols: cols, rows: rows)
    Task { [weak self, transport, terminalKey, cwd] in
      do {
        try await transport.open(sessionId: terminalKey, cwd: cwd, cols: cols, rows: rows)
      } catch {
        self?.report(error.localizedDescription)
      }
    }
  }

  public func attach(_ renderer: any TerminalRenderer) {
    self.renderer = renderer
    let held = pending
    pending = []
    for chunk in held { deliver(chunk.output, replayed: chunk.replayed) }
    if hasExited { renderer.processExited(code: exitCode) }
  }

  public func noteUserInput() {
    lastUserInput = clock()
  }

  public var answersQueries: Bool {
    guard let ptySize, let ownSize else { return true }
    return transport.claimsSize || (ptySize.cols == ownSize.cols && ptySize.rows == ownSize.rows)
  }

  public func produced(_ bytes: [UInt8]) {
    guard let lastUserInput, lastUserInput.duration(to: clock()) < Self.userInputWindow else {
      reply(bytes)
      return
    }
    input(bytes)
  }

  public func reply(_ bytes: [UInt8]) {
    guard !hasExited, !bytes.isEmpty, answersQueries else { return }
    transport.sendReply(String(decoding: bytes, as: UTF8.self))
  }

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

  public var claimsSize: Bool { transport.claimsSize }

  public func focus() {
    guard !hasExited else { return }
    transport.sendFocus()
  }

  public func clear() {
    guard !hasExited else { return }
    transport.sendClear()
  }

  public func setVisible(_ visible: Bool) {
    guard !hasExited else { return }
    if visible {
      transport.reassertSize()
    } else {
      transport.sendHidden()
    }
  }

  public func reconnect() {
    guard !hasExited else { return }
    transport.reconnectNow()
  }

  public func detach() {
    transport.detach()
  }

  public func close() {
    transport.close()
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case let .output(output, replayed):
      deliver(output, replayed: replayed)
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

  private func deliver(_ output: TerminalOutput, replayed: Bool) {
    if !replayed {
      predictor.received(output.text)
      publishPrediction()
    }
    guard let renderer else {
      pending.append((output, replayed))
      return
    }
    if replayed { renderer.writeReplay(output.bytes) } else { renderer.writeLive(output.bytes) }
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

@MainActor
private final class WeakController {
  weak var value: TerminalController?
}
