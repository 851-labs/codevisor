import CoreGraphics
import Foundation

public struct TranscriptRowSet: Sendable {
  public typealias Row = TranscriptPresentationRow

  public var projectedRows: [Row] = [] {
    didSet { projectedRevision &+= 1 }
  }
  private var projectedRevision: UInt64 = 0
  private var resolvedProjectedRevision: UInt64?
  public var activeRows: [Row] = []
  public private(set) var rows: [Row] = []
  public private(set) var rowByKey: [String: Row] = [:]
  public var activeRowsRange: Range<Int>?

  public init() {}

  public struct Resolution: Equatable, Sendable {
    public let rows: [Row]
    public let activeRange: Range<Int>?

    public init(rows: [Row], activeRange: Range<Int>?) {
      self.rows = rows
      self.activeRange = activeRange
    }
  }

  public static func resolve(projectedRows: [Row], activeRows: [Row]) -> Resolution {
    guard
      let activeIndex = projectedRows.firstIndex(where: {
        if case .active = $0.id { true } else { false }
      })
    else { return Resolution(rows: projectedRows, activeRange: nil) }
    guard case let .active(messageID) = projectedRows[activeIndex].id,
      activeRows.first?.id.messageID == messageID
    else {
      return Resolution(rows: projectedRows, activeRange: activeIndex..<(activeIndex + 1))
    }

    var result = projectedRows
    result.replaceSubrange(activeIndex...activeIndex, with: activeRows)
    return Resolution(rows: result, activeRange: activeIndex..<(activeIndex + activeRows.count))
  }

  public static func reversePrependCount(from oldRows: [Row], to newRows: [Row]) -> Int? {
    guard !oldRows.isEmpty, newRows.count > oldRows.count else { return nil }
    let insertedCount = newRows.count - oldRows.count
    guard
      zip(oldRows, newRows.dropFirst(insertedCount)).allSatisfy({ old, new in
        old.id == new.id
      })
    else { return nil }
    return insertedCount
  }

  public static func geometryChanged(from oldRows: [Row], to newRows: [Row]) -> Bool {
    oldRows.count != newRows.count
      || zip(oldRows, newRows).contains { old, new in
        old.id != new.id
          || old.estimatedHeight != new.estimatedHeight
          || old.measurementRevision != new.measurementRevision
      }
  }

  public func geometryChanged(comparedTo newRows: [Row]) -> Bool {
    Self.geometryChanged(from: rows, to: newRows)
  }

  @discardableResult
  public mutating func replaceRows(_ newRows: [Row]) -> [String: Row] {
    let previousRowsByKey = rowByKey
    rows = newRows
    rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
    return previousRowsByKey
  }

  public enum ActiveReplacement: Equatable, Sendable {
    case inPlace(range: Range<Int>, previousRows: [Row])
    case rebuild(rows: [Row])
  }

  public mutating func replaceActiveRows(_ newActiveRows: [Row]) -> ActiveReplacement {
    if resolvedProjectedRevision == projectedRevision,
      let range = activeRowsRange,
      range.count == newActiveRows.count,
      range.upperBound <= rows.count,
      zip(rows[range], newActiveRows).allSatisfy({ $0.layoutKey == $1.layoutKey })
    {
      let previous = Array(rows[range])
      rows.replaceSubrange(range, with: newActiveRows)
      for row in newActiveRows { rowByKey[row.layoutKey] = row }
      activeRows = newActiveRows
      return .inPlace(range: range, previousRows: previous)
    }

    let resolution = Self.resolve(projectedRows: projectedRows, activeRows: newActiveRows)
    activeRows = newActiveRows
    activeRowsRange = resolution.activeRange
    resolvedProjectedRevision = projectedRevision
    return .rebuild(rows: resolution.rows)
  }

  public static func transferActiveHeightIfNeeded(
    from oldRows: [Row],
    to newRows: [Row],
    ledger: inout TranscriptMeasurementLedger
  ) {
    guard let oldActive = oldRows.first(where: { if case .active = $0.id { true } else { false } }),
      let activeHeight = ledger[oldActive.layoutKey],
      !newRows.contains(where: { $0.layoutKey == oldActive.layoutKey })
    else { return }
    let oldKeys = Set(oldRows.map(\.layoutKey))
    let insertedSettledRows = newRows.filter {
      $0.id.isCacheableSettledRow && !oldKeys.contains($0.layoutKey)
    }
    guard insertedSettledRows.count == 1,
      let settledActive = insertedSettledRows.first,
      settledActive.id.messageID == oldActive.id.messageID,
      ledger[settledActive.layoutKey] == nil
    else { return }
    if case .message(.user, _) = settledActive.content { return }
    ledger.setProvisional(activeHeight, for: settledActive.layoutKey)
  }
}
