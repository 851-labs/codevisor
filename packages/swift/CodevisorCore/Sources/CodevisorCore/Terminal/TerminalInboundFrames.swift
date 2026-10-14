import Foundation

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

struct InboundTerminalFrame: Sendable {
  var frame: TerminalServerFrame
  var output: TerminalOutput?
}

final class TerminalInboundFrames: @unchecked Sendable {
  enum Item: Sendable {
    case frame(InboundTerminalFrame)
    case failed
  }

  static let byteLimit = 4 * 1024 * 1024

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
