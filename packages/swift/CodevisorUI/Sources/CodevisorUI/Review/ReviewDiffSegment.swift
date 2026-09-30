import TranscriptKit

/// How much of one folded run the reader has opened, from each end: `top`
/// lines just below the previous hunk ("Show next lines"), `bottom` lines
/// just above the next hunk (expand up from its `@@` header).
struct ReviewGapExpansion: Equatable {
  var top = 0
  var bottom = 0
}

/// A whole-file diff folded for review: changed lines keep a few lines of
/// context, and longer unchanged runs collapse into gaps the reader opens a
/// step at a time from either end, as on GitHub.
enum ReviewDiffSegment: Identifiable, Equatable {
  /// Visible rows. The id is the first row's id.
  case rows([LineDiff.Row])
  /// Folded unchanged rows.
  case gap(Gap)

  struct Gap: Equatable {
    /// The first row of the whole folded run: stable while the reader
    /// opens lines from either end.
    let id: Int
    /// The rows still folded.
    let rows: [LineDiff.Row]
    /// Folded before the first change (nothing above) or after the last
    /// (nothing below).
    let isLeading: Bool
    let isTrailing: Bool
    /// The hunk header (`@@ -a,b +c,d @@`) of the visible rows that follow,
    /// nil for a trailing gap.
    let nextHunkHeader: String?
  }

  var id: Int {
    switch self {
    case let .rows(rows): rows.first?.id ?? -1
    case let .gap(gap): gap.id
    }
  }

  /// Unchanged lines around each change that stay visible.
  static let context = 3
  /// Shorter unchanged runs stay visible: a fold row that hides one or two
  /// lines costs as much space as showing them.
  static let minimumFold = 4
  /// Lines one expand step reveals.
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

    // Open whatever the reader expanded from each end of each run, noting
    // for every line left folded which run it came from.
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

    // Visible runs become row segments; each remaining folded run a gap,
    // identified by the start of its original run.
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

  /// `@@ -oldStart,oldCount +newStart,newCount @@` for the visible rows
  /// starting at `start`, as git prints hunk headers.
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
