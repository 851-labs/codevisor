import ACPKit
import Foundation

extension AssistantTurn {
  public func revision(of entry: TranscriptEntry, parent: String?) -> Int {
    switch entry {
    case let .tool(call): return call.stateRevision ?? 0
    case let .text(id, _): return textStates["\(parent ?? ""):\(id)"]?.revision ?? 0
    case .contextCompaction: return 0
    }
  }

  /// A running turn may last days. Keep a fixed resident window; evicted
  /// entries remain reachable through the same durable detail pager.
  public mutating func boundResidentEntries(itemId: String, limit: Int = 128) {
    if subagents.count > limit {
      let parents = Set(
        (entries + subagents.values.flatMap(\.entries)).compactMap { entry -> String? in
          if case let .tool(call) = entry { return call.toolCallId }; return nil
        })
      subagents = subagents.filter { !$0.value.entries.isEmpty || parents.contains($0.key) }
    }
    let all = entries + subagents.values.flatMap(\.entries)
    guard all.count > limit else { return }
    let answer = finalText
    var retained = Set(
      all.sorted {
        (entryPositions[$0.id] ?? 0) > (entryPositions[$1.id] ?? 0)
      }.prefix(limit).map(\.id))
    for (parent, bucket) in subagents where bucket.entries.contains(where: { retained.contains($0.id) }) {
      retained.insert("tool:\(parent)")
    }
    entries.removeAll { !retained.contains($0.id) }
    subagents = subagents.compactMapValues { bucket in
      var bucket = bucket
      bucket.entries.removeAll { !retained.contains($0.id) }
      return bucket.entries.isEmpty ? nil : bucket
    }
    detailAnswerPreview = answer
    hasDeferredWorkedDetails = true
    deferredDetailItemId = itemId
    detailNextAfter = nil
    detailPreviousBefore = nil
    hasHydratedWorkedDetails = false
    pruneEntryMetadata()
  }

  public mutating func pruneEntryMetadata() {
    let ids = Set((entries + subagents.values.flatMap(\.entries) + [detailAnswerPreview].compactMap { $0 }).map(\.id))
    entryPositions = entryPositions.filter { ids.contains($0.key) }
    textPhases = textPhases.filter { ids.contains("text:\($0.key)") }
    let textKeys = Set(
      entries.compactMap { entry -> String? in
        if case let .text(id, _) = entry { return ":\(id)" }; return nil
      }
        + subagents.flatMap { parent, bucket in
          bucket.entries.compactMap { entry -> String? in
            if case let .text(id, _) = entry { return "\(parent):\(id)" }; return nil
          }
        }
        + [detailAnswerPreview].compactMap { entry -> String? in
          if case let .text(id, _)? = entry { return ":\(id)" }; return nil
        })
    textStates = textStates.filter { textKeys.contains($0.key) }
  }
}
