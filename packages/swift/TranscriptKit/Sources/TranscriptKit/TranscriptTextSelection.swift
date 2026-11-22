import Foundation

public struct TranscriptSelectionPoint: Equatable, Hashable, Sendable {
  public var rowKey: String
  public var surface: Int
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

public struct TranscriptTextSelection: Equatable, Sendable {
  public var anchor: TranscriptSelectionPoint
  public var focus: TranscriptSelectionPoint

  public init(anchor: TranscriptSelectionPoint, focus: TranscriptSelectionPoint) {
    self.anchor = anchor
    self.focus = focus
  }

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
  public static func rowSeparator(
    previous: TranscriptPresentationRow?,
    current: TranscriptPresentationRow?
  ) -> String {
    guard let previous else { return "\n\n" }
    if case let .markdownChunk(chunk) = current?.content, chunk.precedingRole != nil {
      return "\n\n"
    }
    return previous.spacingAfter == 0 ? "\n" : "\n\n"
  }

  public static func prompt(
    in span: TranscriptSelectionSpan,
    surfaceLengths: (_ rowIndex: Int) -> [Int],
    substring: (_ rowIndex: Int, _ surface: Int, _ range: Range<Int>) -> TranscriptQuotedPrompt,
    rowSeparator: (_ rowIndex: Int) -> String,
    surfaceSeparator: String = "\n\n"
  ) -> TranscriptQuotedPrompt {
    var result = TranscriptQuotedPrompt()
    for rowIndex in span.rowRange {
      let ranges = span.surfaceRanges(rowIndex: rowIndex, surfaceLengths: surfaceLengths(rowIndex))
      let pieces = ranges.enumerated().compactMap { surface, range in range.map { substring(rowIndex, surface, $0) } }
        .filter { !$0.text.isEmpty }
      guard let row = joined(pieces, separator: surfaceSeparator) else { continue }
      if !result.text.isEmpty {
        result = result.appending(TranscriptQuotedPrompt(text: rowSeparator(rowIndex)))
      }
      result = result.appending(row)
    }
    return result
  }

  private static func joined(_ pieces: [TranscriptQuotedPrompt], separator: String) -> TranscriptQuotedPrompt? {
    guard let first = pieces.first else { return nil }
    return pieces.dropFirst().reduce(first) { $0.appending(TranscriptQuotedPrompt(text: separator)).appending($1) }
  }
}
