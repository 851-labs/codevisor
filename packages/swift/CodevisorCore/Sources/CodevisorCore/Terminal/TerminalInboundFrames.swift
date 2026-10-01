import Foundation

/// PTY output as both the renderer and the echo predictor need it, built
/// off the main actor: the renderer parses bytes, the predictor scans text.
public struct TerminalOutput: Sendable {
  public var text: String
  public var bytes: [UInt8]

  public init(text: String, bytes: [UInt8]) {
    self.text = text
    self.bytes = bytes
  }

  init(text: String) {
    self.init(text: text, bytes: Array(text.utf8))
  }

  mutating func append(_ other: TerminalOutput) {
    text += other.text
    bytes += other.bytes
  }
}

/// One server frame, decoded off the main actor. Output frames carry their
/// output here (`frame.data` is dropped), ready for the renderer.
struct InboundTerminalFrame: Sendable {
  var frame: TerminalServerFrame
  var output: TerminalOutput?
}

/// The hand-off between a terminal socket's receive loop and the main
/// actor.
///
/// The loop receives and decodes frames on its own task and appends them
/// here; the main actor drains everything queued in one hop. Only one
/// drain is ever outstanding, so while the main thread is busy (rendering,
/// handling the previous batch) a build's flood of output frames piles up
/// here and is handled together instead of costing one main-actor hop
/// each, and consecutive output frames on the same side of the history
/// boundary are merged into one write for the renderer. Order is kept.
/// Back-pressure: the loop stops receiving while `byteLimit` of output
/// waits for the main actor.
final class TerminalInboundFrames: @unchecked Sendable {
  enum Item: Sendable {
    case frame(InboundTerminalFrame)
    /// The socket failed; handled after every frame received before it.
    case failed
  }

  static let byteLimit = 4 * 1024 * 1024

  /// Frames numbered below this were buffered before the attach (or the
  /// reconnect): history, never merged with live output.
  private let liveBoundary: Int
  private let lock = NSLock()
  private var items: [Item] = []
  private var queuedBytes = 0
  private var drainScheduled = false
  private var closed = false
  private var capacityWaiter: CheckedContinuation<Void, Never>?

  init(liveBoundary: Int) {
    self.liveBoundary = liveBoundary
  }

  /// Queues `item` and returns true when the caller must schedule a drain
  /// on the main actor (none is outstanding).
  func append(_ item: Item) -> Bool {
    lock.withLock {
      guard !closed else { return false }
      if case let .frame(incoming) = item, let output = incoming.output {
        queuedBytes += output.bytes.count
        if case var .frame(last) = items.last, canMerge(last, incoming) {
          last.frame.seq = incoming.frame.seq
          last.output?.append(output)
          items[items.count - 1] = .frame(last)
          return schedule()
        }
      }
      items.append(item)
      return schedule()
    }
  }

  /// Everything queued, in order. Called by the drain on the main actor.
  func take() -> [Item] {
    let (taken, waiter) = lock.withLock {
      defer {
        items = []
        queuedBytes = 0
        drainScheduled = false
        capacityWaiter = nil
      }
      return (items, capacityWaiter)
    }
    waiter?.resume()
    return taken
  }

  /// Suspends the receive loop while too much output waits for the main
  /// actor; resumes once it drains (or the socket is torn down).
  func waitForCapacity() async {
    await withCheckedContinuation { continuation in
      let mustWait = lock.withLock {
        guard !closed, queuedBytes >= Self.byteLimit else { return false }
        capacityWaiter = continuation
        return true
      }
      if !mustWait { continuation.resume() }
    }
  }

  /// The socket was torn down: drop what is queued and release the loop.
  func close() {
    let waiter = lock.withLock {
      closed = true
      items = []
      queuedBytes = 0
      defer { capacityWaiter = nil }
      return capacityWaiter
    }
    waiter?.resume()
  }

  private func schedule() -> Bool {
    guard !drainScheduled else { return false }
    drainScheduled = true
    return true
  }

  private func canMerge(_ last: InboundTerminalFrame, _ next: InboundTerminalFrame) -> Bool {
    last.frame.type == "output" && next.frame.type == "output"
      && last.frame.reset != true && next.frame.reset != true
      && last.output != nil
      && (last.frame.seq < liveBoundary) == (next.frame.seq < liveBoundary)
  }
}
