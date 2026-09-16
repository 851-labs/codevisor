import CTreeSitter
import Foundation

/// UTF-16 storage matches Foundation ranges. Line starts are maintained on edits
/// so translating an edit near EOF doesn't scan the entire preceding document.
struct TreeSitterText {
  private(set) var units: [UInt16]
  private(set) var lines: [Int]

  init(_ text: String) {
    units = Array(text.utf16)
    lines = [0] + units.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
  }

  var count: Int { units.count }
  var string: String { String(decoding: units, as: UTF16.self) }

  func point(at offset: Int) -> TSPoint {
    var low = 0
    var high = lines.count
    while low + 1 < high {
      let middle = (low + high) / 2
      if lines[middle] <= offset { low = middle } else { high = middle }
    }
    return TSPoint(row: UInt32(low), column: UInt32((offset - lines[low]) * 2))
  }

  mutating func replace(_ edit: CodeHighlightDocument.Edit) throws -> TSInputEdit {
    let range = edit.range
    guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location
    else { throw TreeSitterError.invalidEdit }
    let inserted = Array(edit.text.utf16)
    guard count - range.length + inserted.count <= Int(UInt32.max) / 2 else { throw TreeSitterError.invalidEdit }
    let start = point(at: range.location)
    let oldEnd = point(at: NSMaxRange(range))
    let delta = inserted.count - range.length
    let before = lines.prefix { $0 <= range.location }
    let after = lines.drop { $0 <= NSMaxRange(range) }.map { $0 + delta }
    let middle = inserted.enumerated().compactMap { $0.element == 10 ? range.location + $0.offset + 1 : nil }
    lines = Array(before) + middle + after
    units.replaceSubrange(range.location..<NSMaxRange(range), with: inserted)
    return TSInputEdit(
      start_byte: UInt32(range.location * 2), old_end_byte: UInt32(NSMaxRange(range) * 2),
      new_end_byte: UInt32((range.location + inserted.count) * 2), start_point: start, old_end_point: oldEnd,
      new_end_point: point(at: range.location + inserted.count))
  }

  func difference(from newSource: String) -> CodeHighlightDocument.Edit? {
    let next = Array(newSource.utf16)
    var prefix = 0
    while prefix < min(count, next.count), units[prefix] == next[prefix] { prefix += 1 }
    if prefix == count, prefix == next.count { return nil }
    // Never cut between the halves of a surrogate pair.
    if prefix > 0, prefix < count, (0xDC00...0xDFFF).contains(units[prefix]) { prefix -= 1 }
    var suffix = 0
    while suffix < min(count, next.count) - prefix, units[count - suffix - 1] == next[next.count - suffix - 1] {
      suffix += 1
    }
    if suffix > 0, (0xDC00...0xDFFF).contains(next[next.count - suffix]) { suffix -= 1 }
    return .init(
      range: NSRange(location: prefix, length: count - prefix - suffix),
      text: String(decoding: next[prefix..<(next.count - suffix)], as: UTF16.self))
  }
}

extension NSRange {
  func translated(by edit: CodeHighlightDocument.Edit) -> NSRange {
    let inserted = edit.text.utf16.count
    let delta = inserted - edit.range.length
    let start = location <= edit.range.location ? location : max(edit.range.location, location + delta)
    let end =
      NSMaxRange(self) < edit.range.location
      ? NSMaxRange(self)
      : max(edit.range.location + inserted, NSMaxRange(self) + delta)
    return NSRange(location: start, length: max(0, end - start))
  }
}
