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
    // Overlapping snapshot and stream ranges converge without replaying text.
    // Keep a bounded preview; the complete message has separately paged storage.
    if patch.offset <= length, length < 24_000 {
      let overlap = length - patch.offset
      let incoming = patch.text as NSString
      if overlap < incoming.length {
        let suffix = incoming.substring(from: overlap)
        var units = Array(suffix.utf16.prefix(24_000 - length))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        existing += String(decoding: units, as: UTF16.self)
      }
    }
    if let index {
      entries[index] = .text(id: id, markdown: existing)
    } else {
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
    for parent in turn.subagents.keys {
      guard var bucket = turn.subagents[parent] else { continue }
      bucket.entries = sorted(bucket.entries)
      turn.subagents[parent] = bucket
    }
  }
}
