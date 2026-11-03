import Foundation

public struct TranscriptQuoteRowText: Equatable, Sendable {
  public var rowKey: String
  public var surfaces: [String]
  public var separatorBefore: String

  public init(rowKey: String, surfaces: [String], separatorBefore: String) {
    self.rowKey = rowKey
    self.surfaces = surfaces
    self.separatorBefore = separatorBefore
  }
}

public enum TranscriptQuoteLocator {
  public static func selection(of quote: String, in rows: [TranscriptQuoteRowText]) -> TranscriptTextSelection? {
    let document = QuoteDocument(rows: rows)
    guard let range = document.range(of: quote) else { return nil }

    return TranscriptTextSelection(
      anchor: document.startPoint(at: range.location),
      focus: document.endPoint(at: NSMaxRange(range))
    )
  }
}

private struct QuoteDocument {
  struct Segment {
    let rowKey: String
    let surface: Int
    let location: Int
    let length: Int

    var end: Int { location + length }
  }

  private(set) var text = ""
  private(set) var segments: [Segment] = []

  init(rows: [TranscriptQuoteRowText]) {
    for row in rows { append(row) }
  }

  func range(of quote: String) -> NSRange? {
    let exact = (text as NSString).range(of: quote)
    if exact.location != NSNotFound, exact.length > 0 { return exact }
    return WhitespaceFoldedText(text).range(of: quote)
  }

  func startPoint(at offset: Int) -> TranscriptSelectionPoint {
    let segment = segments.first { offset < $0.end } ?? segments[segments.count - 1]
    return point(in: segment, offset: offset)
  }

  func endPoint(at offset: Int) -> TranscriptSelectionPoint {
    let segment = segments.last { offset > $0.location } ?? segments[0]
    return point(in: segment, offset: offset)
  }

  private func point(in segment: Segment, offset: Int) -> TranscriptSelectionPoint {
    let clamped = min(max(offset, segment.location), segment.end)
    return TranscriptSelectionPoint(
      rowKey: segment.rowKey, surface: segment.surface, offset: clamped - segment.location)
  }

  private mutating func append(_ row: TranscriptQuoteRowText) {
    let pieces = row.surfaces.enumerated().filter { !$0.element.isEmpty }
    guard !pieces.isEmpty else { return }

    if !text.isEmpty { text += row.separatorBefore }
    for (index, piece) in pieces.enumerated() {
      if index > 0 { text += Self.surfaceSeparator }
      let location = (text as NSString).length
      segments.append(
        Segment(
          rowKey: row.rowKey, surface: piece.offset, location: location, length: (piece.element as NSString).length))
      text += piece.element
    }
  }

  private static let surfaceSeparator = "\n\n"
}

private struct WhitespaceFoldedText {
  private let folded: String
  private let originalOffsets: [Int]

  init(_ text: String) {
    let units = Array(text.utf16)
    var folded: [UInt16] = []
    var offsets: [Int] = []
    for (offset, unit) in units.enumerated() {
      let isSpace = Self.isWhitespace(unit)
      if isSpace, folded.last == Self.space { continue }
      folded.append(isSpace ? Self.space : unit)
      offsets.append(offset)
    }
    self.folded = String(decoding: folded, as: UTF16.self)
    self.originalOffsets = offsets
  }

  func range(of quote: String) -> NSRange? {
    let needle = WhitespaceFoldedText(quote.trimmingCharacters(in: .whitespacesAndNewlines)).folded
    guard !needle.isEmpty else { return nil }

    let found = (folded as NSString).range(of: needle)
    guard found.location != NSNotFound, found.length > 0 else { return nil }

    let start = originalOffsets[found.location]
    let end = originalOffsets[NSMaxRange(found) - 1] + 1
    return NSRange(location: start, length: end - start)
  }

  private static let space: UInt16 = 0x20

  private static func isWhitespace(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0
  }
}
