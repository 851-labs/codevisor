import Foundation

/// One find-in-chat match: the `ordinal`th occurrence of the query inside a
/// row, counting through the row's text surfaces in order.
///
/// Rows are addressed by layout key rather than by view so a match survives
/// the virtualizer unmounting its row; a mounted row re-derives the exact
/// ranges from its own text.
public struct TranscriptFindMatch: Hashable, Sendable {
  public let rowKey: String
  public let ordinal: Int

  public init(rowKey: String, ordinal: Int) {
    self.rowKey = rowKey
    self.ordinal = ordinal
  }
}

/// How many times the query occurs in one searchable row.
public struct TranscriptFindRowCount: Equatable, Sendable {
  public let rowKey: String
  public let count: Int

  public init(rowKey: String, count: Int) {
    self.rowKey = rowKey
    self.count = count
  }
}

/// Every match of the current query in document order, and the one the find
/// bar is on.
///
/// Matches are stored as per-row counts with running offsets rather than one
/// value per occurrence: a one-letter query in a long chat has hundreds of
/// thousands of matches, and the find bar only ever needs the count, the
/// current match, and its neighbors.
public struct TranscriptFindResults: Equatable, Sendable {
  /// Rows with at least one match, in document order.
  public private(set) var rows: [TranscriptFindRowCount] = []
  /// `offsets[i]` is the number of matches before `rows[i]`.
  private var offsets: [Int] = []
  public private(set) var count = 0
  public private(set) var currentIndex: Int?

  public init() {}

  /// Results for a new query. The current match is the first one at or
  /// after `startingRow` (a position in `rows`, typically the first row in
  /// the viewport), or the last match when every match is above it.
  public init(rows counted: [TranscriptFindRowCount], startingRow: Int) {
    var firstAtStart: Int?
    for (position, row) in counted.enumerated() where row.count > 0 {
      if firstAtStart == nil, position >= startingRow { firstAtStart = count }
      append(row)
    }
    guard count > 0 else { return }
    currentIndex = firstAtStart ?? count - 1
  }

  public var isEmpty: Bool { count == 0 }

  public var current: TranscriptFindMatch? {
    currentIndex.map(match(at:))
  }

  /// The match at `index` in document order.
  public func match(at index: Int) -> TranscriptFindMatch {
    precondition((0..<count).contains(index), "Match index out of range")
    // The last row whose first match is at or before `index`.
    var low = 0
    var high = offsets.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if offsets[mid] <= index { low = mid } else { high = mid - 1 }
    }
    return TranscriptFindMatch(rowKey: rows[low].rowKey, ordinal: index - offsets[low])
  }

  /// The current match's ordinal within `rowKey`, or nil when it is in
  /// another row.
  public func currentOrdinal(inRow rowKey: String) -> Int? {
    guard let current, current.rowKey == rowKey else { return nil }
    return current.ordinal
  }

  /// Re-counts after the transcript changed (streaming, pagination, a
  /// collapsed section). The current match stays put when its row still has
  /// it; otherwise the bar lands on the match now at the same position.
  public mutating func update(rows counted: [TranscriptFindRowCount]) {
    let previous = current
    let previousIndex = currentIndex
    rows = []
    offsets = []
    count = 0
    var preserved: Int?
    for row in counted where row.count > 0 {
      if let previous, row.rowKey == previous.rowKey, previous.ordinal < row.count {
        preserved = count + previous.ordinal
      }
      append(row)
    }
    guard count > 0 else {
      currentIndex = nil
      return
    }
    currentIndex = preserved ?? previousIndex.map { min($0, count - 1) } ?? 0
  }

  /// Moves to the next (`delta > 0`) or previous match, wrapping at either
  /// end like a browser's find bar.
  public mutating func step(by delta: Int) {
    guard count > 0 else { return }
    guard let currentIndex else {
      self.currentIndex = delta >= 0 ? 0 : count - 1
      return
    }
    self.currentIndex = ((currentIndex + delta) % count + count) % count
  }

  private mutating func append(_ row: TranscriptFindRowCount) {
    rows.append(row)
    offsets.append(count)
    count += row.count
  }
}
