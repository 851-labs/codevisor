import ACPKit
import CodevisorCore
import Foundation
import Observation

struct DiffTotalsInput: Equatable, Sendable {
  struct Block: Equatable, Sendable {
    let oldText: String?
    let newText: String
  }

  let blocks: [Block]

  init?(_ call: ToolCall) {
    let blocks = (call.content ?? []).compactMap { block -> Block? in
      if case let .diff(_, oldText, newText) = block {
        return Block(oldText: oldText, newText: newText)
      }
      return nil
    }
    guard !blocks.isEmpty else { return nil }
    self.blocks = blocks
  }

  static func key(for call: ToolCall, input: DiffTotalsInput) -> Int {
    var hasher = Hasher()
    hasher.combine(call.toolCallId)
    hasher.combine(call.status)
    for block in input.blocks {
      hasher.combine(block.oldText?.utf8.count ?? -1)
      hasher.combine(block.newText.utf8.count)
    }
    return hasher.finalize()
  }

  func totals() -> LineDiff.Totals {
    blocks.reduce(into: LineDiff.Totals(added: 0, removed: 0)) { totals, block in
      let blockTotals = LineDiff.totals(old: block.oldText, new: block.newText)
      totals.added += blockTotals.added
      totals.removed += blockTotals.removed
    }
  }
}

@MainActor
private final class SettledDiffTotalsCache {
  private struct Entry {
    let input: DiffTotalsInput
    let totals: LineDiff.Totals
  }

  static let shared = SettledDiffTotalsCache()

  private var entries: [Int: Entry] = [:]
  private var order: [Int] = []
  private let limit: Int

  init(limit: Int = 24) {
    self.limit = max(1, limit)
  }

  func totals(for key: Int, input: DiffTotalsInput) -> LineDiff.Totals? {
    guard let entry = entries[key], entry.input == input else { return nil }
    if order.last != key, let index = order.firstIndex(of: key) {
      order.remove(at: index)
      order.append(key)
    }
    return entry.totals
  }

  func store(_ totals: LineDiff.Totals, input: DiffTotalsInput, for key: Int) {
    if entries[key] == nil {
      order.append(key)
      if order.count > limit {
        entries.removeValue(forKey: order.removeFirst())
      }
    }
    entries[key] = Entry(input: input, totals: totals)
  }
}

@MainActor
@Observable
final class DiffTotalsCache {
  private var publishedRevision: UInt64 = 0
  @ObservationIgnored private var value: LineDiff.Totals?
  @ObservationIgnored private var valueKey: Int?
  @ObservationIgnored private var requestedKey: Int?
  @ObservationIgnored private var nextRequest: (key: Int, input: DiffTotalsInput, settled: Bool)?
  @ObservationIgnored private var running: Task<Void, Never>?

  func totals(for call: ToolCall) -> LineDiff.Totals? {
    _ = publishedRevision
    if let diffStats = call.diffStats, !diffStats.isEmpty {
      return call.diffTotals
    }
    guard let input = DiffTotalsInput(call) else { return nil }
    let key = DiffTotalsInput.key(for: call, input: input)
    if key == valueKey { return value }
    if let hit = SettledDiffTotalsCache.shared.totals(for: key, input: input) {
      value = hit
      valueKey = key
      return hit
    }
    request(key: key, input: input, settled: Self.isSettled(call.status))
    return value
  }

  deinit {
    running?.cancel()
  }

  private func request(key: Int, input: DiffTotalsInput, settled: Bool) {
    guard key != requestedKey else { return }
    requestedKey = key
    nextRequest = (key, input, settled)
    if running == nil { runNextRequest() }
  }

  private func runNextRequest() {
    guard let request = nextRequest else {
      running = nil
      return
    }
    nextRequest = nil
    running = Task { [weak self] in
      let input = request.input
      let totals = await Task.detached(priority: .userInitiated) { input.totals() }.value
      guard let self, !Task.isCancelled else { return }
      if request.settled {
        SettledDiffTotalsCache.shared.store(totals, input: request.input, for: request.key)
      }
      self.value = totals
      self.valueKey = request.key
      self.publishedRevision &+= 1
      self.runNextRequest()
    }
  }

  private static func isSettled(_ status: ToolCallStatus?) -> Bool {
    switch status {
    case .completed, .failed, .cancelled: return true
    case .pending, .inProgress, nil: return false
    }
  }
}
