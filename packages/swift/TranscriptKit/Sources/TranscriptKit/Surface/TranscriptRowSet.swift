import CoreGraphics
import Foundation

/// The row book of a native transcript surface: the projected settled rows,
/// the live active-slot rows, and the resolved list the document is laid out
/// from. Shared by the AppKit and UIKit virtualizers so that row resolution,
/// change detection, and in-place active-slice replacement have exactly one
/// implementation.
///
/// Host mounting, measurement invalidation, and document geometry stay with
/// the platform view; this type only answers *what changed* and keeps the
/// three row lists coherent.
public struct TranscriptRowSet: Sendable {
  public typealias Row = TranscriptPresentationRow

  /// Settled rows from the projection worker, with one aggregate `.active`
  /// placeholder while a turn is streaming.
  public var projectedRows: [Row] = []
  /// The active slot's precisely projected rows, spliced over the aggregate
  /// `.active` placeholder in `rows`.
  public var activeRows: [Row] = []
  /// The resolved document order.
  public private(set) var rows: [Row] = []
  public private(set) var rowByKey: [String: Row] = [:]
  /// Where `activeRows` currently sit inside `rows`, if the projection has
  /// an active slot.
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

  /// Splices `activeRows` over the aggregate `.active` placeholder. When
  /// the placeholder belongs to a different message than the active rows,
  /// the placeholder stays and the active range covers only it.
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

  /// The number of rows inserted at the head when `newRows` is `oldRows`
  /// with older history prepended, or nil for any other change.
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

  /// Whether the two lists differ in layout identity or estimates. Deep
  /// content equality is deliberately not consulted: that would walk every
  /// historical Markdown string on each update. Mounted hosts receive fresh
  /// content regardless; unmounted rows stay inert until they enter the
  /// overscan window.
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

  /// Replaces the resolved row list wholesale. Returns the previous key
  /// index so callers can diff mounted hosts and measurements.
  @discardableResult
  public mutating func replaceRows(_ newRows: [Row]) -> [String: Row] {
    let previousRowsByKey = rowByKey
    rows = newRows
    rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
    return previousRowsByKey
  }

  public enum ActiveReplacement: Equatable, Sendable {
    /// The active slice kept its keys and count; `rows` was patched in
    /// place. `previousRows` are the rows that were replaced.
    case inPlace(range: Range<Int>, previousRows: [Row])
    /// The active slice changed shape; the caller must rebuild from the
    /// fully resolved list.
    case rebuild(rows: [Row])
  }

  /// Adopts a new active slice. When it is key-stable with the current one,
  /// `rows` is patched in place and only the replaced rows are reported;
  /// otherwise the caller is handed the resolved list to rebuild from.
  /// `activeRows` and `activeRowsRange` are updated in both cases.
  public mutating func replaceActiveRows(_ newActiveRows: [Row]) -> ActiveReplacement {
    let resolution = Self.resolve(projectedRows: projectedRows, activeRows: newActiveRows)
    defer {
      activeRows = newActiveRows
      activeRowsRange = resolution.activeRange
    }
    guard let oldRange = activeRowsRange,
      let newRange = resolution.activeRange,
      oldRange.count == newRange.count,
      oldRange.upperBound <= rows.count
    else {
      return .rebuild(rows: resolution.rows)
    }

    let previousRows = Array(rows[oldRange])
    let replacement = Array(resolution.rows[newRange])
    guard zip(previousRows, replacement).allSatisfy({ $0.layoutKey == $1.layoutKey }) else {
      return .rebuild(rows: resolution.rows)
    }

    rows.replaceSubrange(oldRange, with: replacement)
    for row in replacement {
      rowByKey[row.layoutKey] = row
    }
    return .inPlace(range: oldRange, previousRows: previousRows)
  }

  /// Carries the aggregate active host's measured height onto the single
  /// settled row that replaces it, as a provisional (never authoritative)
  /// measurement. A plan turn intentionally becomes multiple independently
  /// measured rows, so assigning the aggregate to any one slice would poison
  /// scroll geometry; in that case nothing is transferred.
  public static func transferActiveHeightIfNeeded(
    from oldRows: [Row],
    to newRows: [Row],
    ledger: inout TranscriptMeasurementLedger
  ) {
    guard let oldActive = oldRows.first(where: { $0.id.isActiveRow }),
      let activeHeight = ledger[oldActive.layoutKey],
      !newRows.contains(where: { $0.layoutKey == oldActive.layoutKey })
    else { return }
    let oldKeys = Set(oldRows.map(\.layoutKey))
    let insertedSettledRows = newRows.filter {
      $0.id.isCacheableSettledRow && !oldKeys.contains($0.layoutKey)
    }
    guard insertedSettledRows.count == 1,
      let settledActive = insertedSettledRows.first,
      ledger[settledActive.layoutKey] == nil
    else { return }
    // The settled render (auto-collapsed worked section, answer hoisted
    // out of it) differs from the streaming render, so the streaming
    // height positions rows until the settled host measures — but it must
    // not be written into revision-keyed caches where it could outlive
    // this mount as an "exact" measurement.
    ledger.setProvisional(activeHeight, for: settledActive.layoutKey)
  }
}
