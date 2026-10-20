import Foundation

public struct UnifiedDiff: Equatable, Sendable {
  public struct File: Equatable, Sendable, Identifiable {
    public let id: Int
    public let path: String
    public let hunks: [Hunk]

    public var rows: [LineDiff.Row] { hunks.flatMap(\.rows) }

    public var totals: LineDiff.Totals {
      rows.reduce(into: LineDiff.Totals(added: 0, removed: 0)) { totals, row in
        switch row.kind {
        case .context: break
        case .added: totals.added += 1
        case .removed: totals.removed += 1
        }
      }
    }

    public var maxLineNumber: Int {
      rows.reduce(1) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
    }
  }

  public struct Hunk: Equatable, Sendable, Identifiable {
    public let id: Int
    public let header: String
    public let rows: [LineDiff.Row]
  }

  public let files: [File]

  public init?(parsing text: String) {
    var parser = UnifiedDiffParser()
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      parser.consume(line)
    }
    let files = parser.finish()
    guard files.contains(where: { !$0.hunks.isEmpty }) else { return nil }
    self.files = files
  }
}

private struct UnifiedDiffParser {
  private var files: [UnifiedDiff.File] = []
  private var path = ""
  private var hunks: [UnifiedDiff.Hunk] = []
  private var hunk: HunkDraft?
  private var hasFile = false
  private var nextRowID = 0

  mutating func consume(_ line: Substring) {
    if hunk?.isOpen == true, appendRow(line) { return }
    closeHunk()
    consumeHeader(line)
  }

  mutating func finish() -> [UnifiedDiff.File] {
    closeFile()
    return files
  }

  private mutating func consumeHeader(_ line: Substring) {
    if line.hasPrefix("diff --git ") {
      startFile(path: gitPath(line))
    } else if line.hasPrefix("--- ") {
      if !hasFile || !hunks.isEmpty { startFile(path: markerPath(line)) }
    } else if line.hasPrefix("+++ ") {
      let newPath = markerPath(line)
      if newPath != "/dev/null" { path = newPath }
    } else if let header = HunkHeader(line) {
      if !hasFile { startFile(path: "") }
      hunk = HunkDraft(header: header)
    }
  }

  private mutating func appendRow(_ line: Substring) -> Bool {
    guard var draft = hunk, let row = draft.row(for: line, id: nextRowID) else {
      return line.hasPrefix("\\")
    }
    nextRowID += 1
    draft.rows.append(row)
    hunk = draft
    return true
  }

  private mutating func startFile(path: String) {
    closeFile()
    self.path = path
    hasFile = true
  }

  private mutating func closeHunk() {
    guard let draft = hunk else { return }
    hunks.append(UnifiedDiff.Hunk(id: hunks.count, header: draft.header.text, rows: draft.rows))
    hunk = nil
  }

  private mutating func closeFile() {
    closeHunk()
    guard hasFile else { return }
    files.append(UnifiedDiff.File(id: files.count, path: path, hunks: hunks))
    hunks = []
    nextRowID = 0
  }

  private func gitPath(_ line: Substring) -> String {
    guard let range = line.range(of: " b/", options: .backwards) else { return "" }
    return String(line[range.upperBound...])
  }

  private func markerPath(_ line: Substring) -> String {
    let path = line.dropFirst(4).split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
    guard path.hasPrefix("a/") || path.hasPrefix("b/") else { return path }
    return String(path.dropFirst(2))
  }
}

private struct HunkHeader {
  private static let expression = try! NSRegularExpression(
    pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
  )

  let text: String
  let oldStart: Int
  let oldCount: Int
  let newStart: Int
  let newCount: Int

  init?(_ line: Substring) {
    let text = String(line)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = Self.expression.firstMatch(in: text, range: range) else { return nil }
    let number = { (group: Int, fallback: Int) -> Int in
      Range(match.range(at: group), in: text).flatMap { Int(text[$0]) } ?? fallback
    }
    self.text = text
    oldStart = number(1, 0)
    oldCount = number(2, 1)
    newStart = number(3, 0)
    newCount = number(4, 1)
  }
}

private struct HunkDraft {
  let header: HunkHeader
  var rows: [LineDiff.Row] = []
  private var oldLine: Int
  private var newLine: Int
  private var oldRemaining: Int
  private var newRemaining: Int

  init(header: HunkHeader) {
    self.header = header
    oldLine = header.oldStart
    newLine = header.newStart
    oldRemaining = header.oldCount
    newRemaining = header.newCount
  }

  var isOpen: Bool { oldRemaining > 0 || newRemaining > 0 }

  mutating func row(for line: Substring, id: Int) -> LineDiff.Row? {
    let text = String(line.dropFirst())
    switch line.first {
    case "+" where newRemaining > 0: return added(text, id: id)
    case "-" where oldRemaining > 0: return removed(text, id: id)
    case " ", nil: return context(text, id: id)
    default: return nil
    }
  }

  private mutating func added(_ text: String, id: Int) -> LineDiff.Row {
    defer { newLine += 1; newRemaining -= 1 }
    return LineDiff.Row(id: id, kind: .added, oldLine: nil, newLine: newLine, text: text)
  }

  private mutating func removed(_ text: String, id: Int) -> LineDiff.Row {
    defer { oldLine += 1; oldRemaining -= 1 }
    return LineDiff.Row(id: id, kind: .removed, oldLine: oldLine, newLine: nil, text: text)
  }

  private mutating func context(_ text: String, id: Int) -> LineDiff.Row {
    defer { oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1 }
    return LineDiff.Row(id: id, kind: .context, oldLine: oldLine, newLine: newLine, text: text)
  }
}
