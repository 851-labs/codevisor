import ACPKit
import CodevisorCore
import Foundation
import Observation

/// The old/new text of an edit's diff blocks: the input of its +N/−N
/// counter when the adapter streams no `diffStats`.
struct DiffTotalsInput: Equatable, Sendable {
  struct Block: Equatable, Sendable {
    let oldText: String?
    let newText: String
  }

  let blocks: [Block]

  init?(_ call: ToolCall) {
    let blocks = (call.content ?? []).compactMap { block -> Block? in
      if case let .diff(_, oldText, newText) = block {
        // Strings are copy-on-write: this retains rather than copies.
        return Block(oldText: oldText, newText: newText)
      }
      return nil
    }
    guard !blocks.isEmpty else { return nil }
    self.blocks = blocks
  }

  /// Call id, status and each block's text lengths. Costs no content
  /// hashing, and moves with every streamed edit (the text grows) and with
  /// settlement.
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

  /// A Myers diff over each block's whole old and new text: run off the
  /// main thread only.
  func totals() -> LineDiff.Totals {
    blocks.reduce(into: LineDiff.Totals(added: 0, removed: 0)) { totals, block in
      let blockTotals = LineDiff.totals(old: block.oldText, new: block.newText)
      totals.added += blockTotals.added
      totals.removed += blockTotals.removed
    }
  }
}

/// Process-level memo for the content-diff fallback of `diffTotals`, holding
/// SETTLED results only.
///
/// The per-row `DiffTotalsCache` below lives in `@State`, so it dies whenever
/// its row unmounts — a `LazyVStack` scroll past the viewport buffer, or a tab
/// switch, which rebuilds the whole chat screen. Revisiting an edit therefore
/// re-diffed the file's entire old and new text. Same rationale (and cap) as
/// `DiffRenderCache`.
///
/// Entries are found by the cheap length key and confirmed by comparing the
/// texts, never by a hash alone: a collision would render the wrong +N/−N.
/// A remounted row's strings share storage with the stored ones, so the
/// comparison is usually an identity check rather than a scan, and nothing
/// hashes whole files on the main thread. In-progress calls are deliberately
/// NOT stored — streaming rewrites their text every flush, so admitting
/// intermediates would evict the settled entries that revisits actually
/// re-encounter (the lesson already recorded on `MarkdownSegmentCache` and
/// `CodeHighlightResultCache`).
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

  /// Entries hold the full old/new texts, so the cap stays small.
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

/// `ToolCall.diffTotals` for a row, without diffing on the main thread.
/// Streamed `diffStats` are a cheap sum and pass straight through. The
/// content-diff fallback (a Myers diff over the whole file's old/new text)
/// runs in a detached task whenever the change key — call id, status, and
/// each diff block's text lengths — moves; until it lands, the row keeps
/// showing the previous totals (none, the first time), and the result
/// publishes through Observation so the row re-renders with it.
///
/// One diff runs at a time per row: a stream flush that changes the text
/// while one is running only replaces the next request, so streaming never
/// queues a backlog of whole-file diffs.
@MainActor
@Observable
final class DiffTotalsCache {
  /// Bumped when a background diff lands. Read by `totals(for:)` so the
  /// view that asked re-renders with the result.
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
    // A remounted settled row finds its earlier result without a diff.
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
