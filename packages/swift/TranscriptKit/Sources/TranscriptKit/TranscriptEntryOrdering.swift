import ACPKit
import Foundation

enum TranscriptEntryOrdering {
  static func orderEntries(_ turn: inout AssistantTurn) {
    let positions = turn.entryPositions
    // An entry without a durable position (live-only rows such as a
    // compaction marker, or an older server's answered question) stays
    // anchored behind whatever preceded it when it arrived. Sorting it to
    // the end instead would drag it past every later tool call, so it
    // would keep reappearing in the newest "Worked for" group.
    func sorted(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
      guard entries.count > 1 else { return entries }
      var anchor = Int.min
      let keys = entries.map { entry in
        if let position = positions[entry.id] { anchor = position }
        return anchor
      }
      if zip(keys, keys.dropFirst()).allSatisfy({ $0 <= $1 }) { return entries }
      return entries.indices.sorted {
        keys[$0] == keys[$1] ? $0 < $1 : keys[$0] < keys[$1]
      }.map { entries[$0] }
    }
    turn.entries = sorted(turn.entries)
    if turn.planDocument != nil, turn.planRevision > 0 {
      // The answer summary may be present before earlier work is restored.
      // Derive the split from durable order, not the order pages were loaded.
      turn.planBoundary =
        turn.entries.prefix {
          (positions[$0.id] ?? Int.max) <= turn.planRevision
        }.count
    }
    for parent in turn.subagents.keys {
      guard var bucket = turn.subagents[parent] else { continue }
      bucket.entries = sorted(bucket.entries)
      turn.subagents[parent] = bucket
    }
  }

  static func applyContextCompaction(
    id: String?,
    status: ContextCompactionStatus,
    entries: inout [TranscriptEntry]
  ) {
    let matchingIndex: Int? =
      if let id {
        entries.firstIndex {
          if case let .contextCompaction(existingId, _) = $0 { return existingId == id }
          return false
        }
      } else {
        entries.lastIndex {
          if case .contextCompaction = $0 { return true }
          return false
        }
      }

    switch status {
    case .started:
      startCompaction(id: id, matchingIndex: matchingIndex, entries: &entries)
    case .completed:
      completeCompaction(id: id, matchingIndex: matchingIndex, entries: &entries)
    case .failed:
      if let matchingIndex { entries.remove(at: matchingIndex) }
    }
  }

  private static func nextLegacyCompactionId(in entries: [TranscriptEntry]) -> String {
    let ids = Set(
      entries.compactMap { entry -> String? in
        if case let .contextCompaction(id, _) = entry { return id }
        return nil
      })
    var offset = ids.count
    while ids.contains("legacy-\(offset)") { offset += 1 }
    return "legacy-\(offset)"
  }

  private static func startCompaction(id: String?, matchingIndex: Int?, entries: inout [TranscriptEntry]) {
    if let matchingIndex, let id {
      entries[matchingIndex] = .contextCompaction(id: id, status: .started)
    } else {
      entries.append(
        .contextCompaction(
          id: id ?? nextLegacyCompactionId(in: entries),
          status: .started
        ))
    }
  }

  private static func completeCompaction(id: String?, matchingIndex: Int?, entries: inout [TranscriptEntry]) {
    if let matchingIndex, case let .contextCompaction(existingId, _) = entries[matchingIndex] {
      entries[matchingIndex] = .contextCompaction(id: existingId, status: .completed)
    } else if let id {
      // A client can attach between lifecycle notifications. Preserve
      // the only position it observed instead of dropping completion.
      entries.append(.contextCompaction(id: id, status: .completed))
    }
  }
}
