import Foundation

/// One end of a transcript-wide text selection: a character offset inside one
/// text surface of one virtualized row.
///
/// Rows are addressed by layout key rather than by view because the
/// virtualizer unmounts and recycles hosts freely; ordering is resolved
/// against the current layout on demand. `surface` counts the row's text
/// surfaces from top to bottom. `Int.max` in either field means "past the end
/// of the row", which lets a selection reach a row without knowing how many
/// surfaces it has.
public struct TranscriptSelectionPoint: Equatable, Hashable, Sendable {
  public var rowKey: String
  public var surface: Int
  /// UTF-16 offset within the surface.
  public var offset: Int

  public init(rowKey: String, surface: Int, offset: Int) {
    self.rowKey = rowKey
    self.surface = surface
    self.offset = offset
  }

  public static func rowStart(_ rowKey: String) -> TranscriptSelectionPoint {
    TranscriptSelectionPoint(rowKey: rowKey, surface: 0, offset: 0)
  }

  public static func rowEnd(_ rowKey: String) -> TranscriptSelectionPoint {
    TranscriptSelectionPoint(rowKey: rowKey, surface: .max, offset: .max)
  }
}

/// An anchor/focus pair. The anchor is where the gesture started; the focus
/// follows the pointer, so either may come first in document order.
public struct TranscriptTextSelection: Equatable, Sendable {
  public var anchor: TranscriptSelectionPoint
  public var focus: TranscriptSelectionPoint

  public init(anchor: TranscriptSelectionPoint, focus: TranscriptSelectionPoint) {
    self.anchor = anchor
    self.focus = focus
  }

  /// Orders the endpoints using the current row order. Returns nil when
  /// either endpoint's row is no longer in the layout.
  public func resolve(rowIndex: (String) -> Int?) -> TranscriptSelectionSpan? {
    guard let anchorRow = rowIndex(anchor.rowKey),
      let focusRow = rowIndex(focus.rowKey)
    else { return nil }
    let anchorKey = (anchorRow, anchor.surface, anchor.offset)
    let focusKey = (focusRow, focus.surface, focus.offset)
    if anchorKey <= focusKey {
      return TranscriptSelectionSpan(start: anchor, startRow: anchorRow, end: focus, endRow: focusRow)
    }
    return TranscriptSelectionSpan(start: focus, startRow: focusRow, end: anchor, endRow: anchorRow)
  }
}

/// A selection whose endpoints have been ordered against a concrete layout.
public struct TranscriptSelectionSpan: Equatable, Sendable {
  public let start: TranscriptSelectionPoint
  public let startRow: Int
  public let end: TranscriptSelectionPoint
  public let endRow: Int

  public init(
    start: TranscriptSelectionPoint,
    startRow: Int,
    end: TranscriptSelectionPoint,
    endRow: Int
  ) {
    self.start = start
    self.startRow = startRow
    self.end = end
    self.endRow = endRow
  }

  public var isEmpty: Bool {
    startRow == endRow && start.surface == end.surface && start.offset == end.offset
  }

  public var rowRange: ClosedRange<Int> { startRow...endRow }

  public func contains(rowIndex: Int) -> Bool {
    rowRange.contains(rowIndex)
  }

  /// The selected portion of each surface in one row, given the surfaces'
  /// lengths. `nil` marks a surface the selection does not touch.
  public func surfaceRanges(rowIndex: Int, surfaceLengths: [Int]) -> [Range<Int>?] {
    guard contains(rowIndex: rowIndex) else {
      return Array(repeating: nil, count: surfaceLengths.count)
    }
    return surfaceLengths.enumerated().map { surface, length in
      var lower = 0
      var upper = length
      if rowIndex == startRow {
        if surface < start.surface { return nil }
        if surface == start.surface { lower = min(start.offset, length) }
      }
      if rowIndex == endRow {
        if surface > end.surface { return nil }
        if surface == end.surface { upper = min(end.offset, length) }
      }
      guard lower < upper else { return nil }
      return lower..<upper
    }
  }
}

public enum TranscriptSelectionText {
  /// Assembles the plain text covered by `span`.
  ///
  /// Rows contribute their surfaces in order. Surfaces within a row are
  /// joined by a blank line; `rowSeparator` decides how each subsequent row is
  /// joined to the text before it (typically a newline inside a fragmented
  /// list, a blank line otherwise). Rows and surfaces that contribute nothing
  /// are skipped so separators never pile up.
  public static func text(
    in span: TranscriptSelectionSpan,
    surfaceLengths: (_ rowIndex: Int) -> [Int],
    substring: (_ rowIndex: Int, _ surface: Int, _ range: Range<Int>) -> String,
    rowSeparator: (_ rowIndex: Int) -> String,
    surfaceSeparator: String = "\n\n"
  ) -> String {
    var result = ""
    for rowIndex in span.rowRange {
      let ranges = span.surfaceRanges(rowIndex: rowIndex, surfaceLengths: surfaceLengths(rowIndex))
      var pieces: [String] = []
      for (surface, range) in ranges.enumerated() {
        guard let range else { continue }
        let piece = substring(rowIndex, surface, range)
        if !piece.isEmpty { pieces.append(piece) }
      }
      guard !pieces.isEmpty else { continue }
      if !result.isEmpty {
        result += rowSeparator(rowIndex)
      }
      result += pieces.joined(separator: surfaceSeparator)
    }
    return result
  }

  /// UTF-16 slicing that tolerates ranges past the end of a shorter string.
  public static func substring(of text: String, in range: Range<Int>) -> String {
    let nsText = text as NSString
    let lower = min(max(0, range.lowerBound), nsText.length)
    let upper = min(max(lower, range.upperBound), nsText.length)
    guard lower < upper else { return "" }
    return nsText.substring(with: NSRange(location: lower, length: upper - lower))
  }
}
