import Foundation

public enum LineDiff {
  public struct Row: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
      case context, added, removed
    }

    public let id: Int
    public let kind: Kind
    public let oldLine: Int?
    public let newLine: Int?
    public let text: String
  }

  public struct Totals: Sendable, Equatable {
    public var added: Int
    public var removed: Int

    public init(added: Int, removed: Int) {
      self.added = added
      self.removed = removed
    }
  }

  public static func rows(old: String?, new: String) -> [Row] {
    let oldLines = lines(of: old ?? "")
    let newLines = lines(of: new)
    let difference = newLines.difference(from: oldLines)
    var removalOffsets = Set<Int>()
    var insertionOffsets = Set<Int>()
    for change in difference {
      switch change {
      case let .remove(offset, _, _): removalOffsets.insert(offset)
      case let .insert(offset, _, _): insertionOffsets.insert(offset)
      }
    }

    var rows: [Row] = []
    var oldIndex = 0
    var newIndex = 0
    while oldIndex < oldLines.count || newIndex < newLines.count {
      while oldIndex < oldLines.count, removalOffsets.contains(oldIndex) {
        rows.append(
          Row(id: rows.count, kind: .removed, oldLine: oldIndex + 1, newLine: nil, text: oldLines[oldIndex]))
        oldIndex += 1
      }
      while newIndex < newLines.count, insertionOffsets.contains(newIndex) {
        rows.append(
          Row(id: rows.count, kind: .added, oldLine: nil, newLine: newIndex + 1, text: newLines[newIndex]))
        newIndex += 1
      }
      if oldIndex < oldLines.count, newIndex < newLines.count,
        !removalOffsets.contains(oldIndex), !insertionOffsets.contains(newIndex)
      {
        rows.append(
          Row(
            id: rows.count, kind: .context, oldLine: oldIndex + 1, newLine: newIndex + 1,
            text: newLines[newIndex]))
        oldIndex += 1
        newIndex += 1
      }
    }
    return rows
  }

  public static func dedent(old: String?, new: String) -> (old: String?, new: String) {
    let prefix = commonIndent(of: lines(of: old ?? "") + lines(of: new))
    guard !prefix.isEmpty else { return (old, new) }
    return (old.map { strip(prefix, fromEachLineOf: $0) }, strip(prefix, fromEachLineOf: new))
  }

  private static func commonIndent(of lines: [String]) -> Substring {
    var common: Substring?
    for line in lines {
      guard !line.isEmpty, !line.allSatisfy(\.isWhitespace) else { continue }
      let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
      common = common.map { sharedPrefix($0, indent) } ?? indent
      if common?.isEmpty == true { break }
    }
    return common ?? Substring()
  }

  private static func sharedPrefix(_ a: Substring, _ b: Substring) -> Substring {
    var aIndex = a.startIndex
    var bIndex = b.startIndex
    while aIndex < a.endIndex, bIndex < b.endIndex, a[aIndex] == b[bIndex] {
      aIndex = a.index(after: aIndex)
      bIndex = b.index(after: bIndex)
    }
    return a[a.startIndex..<aIndex]
  }

  private static func strip(_ prefix: Substring, fromEachLineOf text: String) -> String {
    text.components(separatedBy: "\n").map { line in
      if line.starts(with: prefix) { return String(line.dropFirst(prefix.count)) }
      return line.allSatisfy(\.isWhitespace) ? "" : line
    }.joined(separator: "\n")
  }

  public static func totals(old: String?, new: String) -> Totals {
    let difference = lines(of: new).difference(from: lines(of: old ?? ""))
    return Totals(added: difference.insertions.count, removed: difference.removals.count)
  }

  private static func lines(of text: String) -> [String] {
    if text.isEmpty { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }
}
