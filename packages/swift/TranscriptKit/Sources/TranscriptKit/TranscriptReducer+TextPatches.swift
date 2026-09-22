import ACPKit
import Foundation

public struct TranscriptTextState: Equatable, Sendable {
  public var generation: Int
  public var revision: Int
  public var resource: ToolDetailResource?

  public init(generation: Int, revision: Int, resource: ToolDetailResource? = nil) {
    self.generation = generation
    self.revision = revision
    self.resource = resource
  }
}

extension TranscriptReducer {
  static func applyTextPatch(_ patch: AgentMessagePatch, to turn: inout AssistantTurn) {
    let id = "acp:\(patch.messageId)"
    let stateKey = "\(patch.parentToolCallId ?? ""):\(id)"
    if let position = patch.statePosition { turn.entryPositions["text:\(id)"] = position }
    let old = turn.textStates[stateKey]
    guard patch.offset >= 0, patch.generation >= (old?.generation ?? 0) else { return }
    let replaces = old != nil && patch.generation > old!.generation
    var entries = patch.parentToolCallId.map { turn.subagents[$0]?.entries ?? [] } ?? turn.entries
    let index = entries.firstIndex { $0.id == "text:\(id)" }
    var existing = ""
    if !replaces, let index, case let .text(_, text) = entries[index] { existing = text }
    let length = existing.utf16.count
    // Storage snapshots and live deltas converge on the same complete text.
    // Rendering keeps its original identity and streaming path at every length.
    if patch.offset <= length {
      let overlap = length - patch.offset
      let incoming = patch.text as NSString
      if overlap < incoming.length {
        existing += incoming.substring(from: overlap)
      }
    }
    if let index {
      entries[index] = .text(id: id, markdown: existing)
    } else if !existing.isEmpty {
      // A zero-length span contributes no content and shifts no later
      // offset, so it is never materialized. Whitespace-only spans DO carry
      // length that subsequent patch offsets are measured against, so they
      // are stored and filtered at presentation (`isBlankText`) instead.
      entries.append(.text(id: id, markdown: existing))
    }
    let newest = patch.stateRevision >= (old?.revision ?? 0) || replaces
    let resource = patch.totalLength > existing.utf16.count ? patch.detailResource ?? old?.resource : nil
    turn.textStates[stateKey] = TranscriptTextState(
      generation: patch.generation, revision: max(patch.stateRevision, old?.revision ?? 0),
      resource: newest ? resource : old?.resource)
    if let parent = patch.parentToolCallId {
      var bucket = turn.subagents[parent] ?? SubagentTranscript()
      bucket.entries = entries
      bucket.isThinking = false
      turn.subagents[parent] = bucket
    } else {
      turn.entries = entries
      turn.isThinking = false
      if newest, let phase = patch.phase { turn.textPhases[id] = phase }
    }
  }
}

extension TranscriptReducer {
  public static func orderEntries(_ turn: inout AssistantTurn) {
    let positions = turn.entryPositions
    func sorted(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
      guard entries.count > 1 else { return entries }
      let indexed = entries.enumerated()
      var previous = Int.min
      let ordered = entries.allSatisfy { entry in
        let position = positions[entry.id] ?? Int.max
        defer { previous = position }
        return position >= previous
      }
      if ordered { return entries }
      return indexed.sorted {
        let left = positions[$0.element.id] ?? Int.max
        let right = positions[$1.element.id] ?? Int.max
        return left == right ? $0.offset < $1.offset : left < right
      }.map(\.element)
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
}
