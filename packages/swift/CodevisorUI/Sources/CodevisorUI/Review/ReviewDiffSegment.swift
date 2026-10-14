import TranscriptKit

struct ReviewGapExpansion: Equatable {
  var top = 0
  var bottom = 0
}

enum ReviewDiffSegment: Identifiable, Equatable {
  case rows([LineDiff.Row])
  case gap(Gap)

  struct Gap: Equatable {
    let id: Int
    let rows: [LineDiff.Row]
    let isLeading: Bool
    let isTrailing: Bool
    let nextHunkHeader: String?
  }

  var id: Int {
    switch self {
    case let .rows(rows): rows.first?.id ?? -1
    case let .gap(gap): gap.id
    }
  }

  static let context = 3
  static let minimumFold = 4
  static let expandStep = 20

  static func segments(
    for rows: [LineDiff.Row],
    expansions: [Int: ReviewGapExpansion] = [:]
  ) -> [ReviewDiffSegment] {
    guard !rows.isEmpty else { return [] }
    var visible = [Bool](repeating: false, count: rows.count)
    for (index, row) in rows.enumerated() where row.kind != .context {
      let lower = max(0, index - context)
      let upper = min(rows.count - 1, index + context)
      for near in lower...upper { visible[near] = true }
    }

    var runStart = [Int](repeating: -1, count: rows.count)
    var index = 0
    while index < rows.count {
      guard !visible[index] else {
        index += 1
        continue
      }
      var end = index
      while end < rows.count, !visible[end] { end += 1 }
      let count = end - index
      let expansion = expansions[rows[index].id] ?? ReviewGapExpansion()
      if count < minimumFold || expansion.top + expansion.bottom >= count {
        for open in index..<end { visible[open] = true }
      } else {
        for open in index..<(index + expansion.top) { visible[open] = true }
        for open in (end - expansion.bottom)..<end { visible[open] = true }
        for folded in (index + expansion.top)..<(end - expansion.bottom) { runStart[folded] = rows[index].id }
      }
      index = end
    }

    let firstChange = rows.firstIndex { $0.kind != .context } ?? rows.count
    let lastChange = rows.lastIndex { $0.kind != .context } ?? -1

    var segments: [ReviewDiffSegment] = []
    var shown: [LineDiff.Row] = []
    index = 0
    while index < rows.count {
      if visible[index] {
        shown.append(rows[index])
        index += 1
        continue
      }
      var end = index
      while end < rows.count, !visible[end] { end += 1 }
      if !shown.isEmpty { segments.append(.rows(shown)) }
      shown = []
      segments.append(
        .gap(
          Gap(
            id: runStart[index],
            rows: Array(rows[index..<end]),
            isLeading: index < firstChange,
            isTrailing: end > lastChange,
            nextHunkHeader: hunkHeader(in: rows, from: end, visible: visible)
          )))
      index = end
    }
    if !shown.isEmpty { segments.append(.rows(shown)) }
    return segments
  }

  private static func hunkHeader(in rows: [LineDiff.Row], from start: Int, visible: [Bool]) -> String? {
    guard start < rows.count else { return nil }
    var end = start
    while end < rows.count, visible[end] { end += 1 }
    let hunk = rows[start..<end]
    let old = hunk.compactMap(\.oldLine)
    let new = hunk.compactMap(\.newLine)
    let oldStart = old.first ?? max(0, (rows[..<start].last { $0.oldLine != nil }?.oldLine ?? 0))
    let newStart = new.first ?? max(0, (rows[..<start].last { $0.newLine != nil }?.newLine ?? 0))
    return "@@ -\(oldStart),\(old.count) +\(newStart),\(new.count) @@"
  }
}
