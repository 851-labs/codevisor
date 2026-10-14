import Foundation

public struct TranscriptFindMatch: Hashable, Sendable {
  public let rowKey: String
  public let ordinal: Int

  public init(rowKey: String, ordinal: Int) {
    self.rowKey = rowKey
    self.ordinal = ordinal
  }
}

public struct TranscriptFindRowCount: Equatable, Sendable {
  public let rowKey: String
  public let count: Int

  public init(rowKey: String, count: Int) {
    self.rowKey = rowKey
    self.count = count
  }
}

public struct TranscriptFindResults: Equatable, Sendable {
  public private(set) var rows: [TranscriptFindRowCount] = []
  private var offsets: [Int] = []
  public private(set) var count = 0
  public private(set) var currentIndex: Int?

  public init() {}

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

  public func match(at index: Int) -> TranscriptFindMatch {
    precondition((0..<count).contains(index), "Match index out of range")
    var low = 0
    var high = offsets.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if offsets[mid] <= index { low = mid } else { high = mid - 1 }
    }
    return TranscriptFindMatch(rowKey: rows[low].rowKey, ordinal: index - offsets[low])
  }

  public func currentOrdinal(inRow rowKey: String) -> Int? {
    guard let current, current.rowKey == rowKey else { return nil }
    return current.ordinal
  }

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
