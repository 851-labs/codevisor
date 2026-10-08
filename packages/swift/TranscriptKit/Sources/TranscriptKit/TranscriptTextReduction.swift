import ACPKit
import Foundation

enum TranscriptTextReduction {
  static func applyChunk(
    _ block: ContentBlock, messageId: String?, parentToolCallId: String?, phase: MessagePhase?,
    to turn: inout AssistantTurn
  ) {
    if let parent = parentToolCallId {
      var bucket = turn.subagents[parent] ?? SubagentTranscript()
      bucket.isThinking = false
      appendText(
        text(from: block), messageId: messageId, entries: &bucket.entries, nextTextId: &bucket.nextTextId)
      turn.subagents[parent] = bucket
    } else {
      turn.isThinking = false
      let entryId = appendText(
        text(from: block), messageId: messageId, entries: &turn.entries, nextTextId: &turn.nextTextId)
      // Finality rides per chunk (codex tags whole messages) or as a
      // zero-length retro-tag (Claude demoting streamed preamble once
      // a tool call starts). Keyed by entry id so `finalText` can
      // skip commentary spans; subagent threads never split a final
      // answer out, so phases are main-thread only.
      if let phase, let entryId {
        turn.textPhases[entryId] = phase
      }
    }
  }

  static func applyThought(parentToolCallId: String?, to turn: inout AssistantTurn) {
    // Thoughts surface only as the ephemeral "Thinking…" indicator; they
    // are not persisted as transcript entries.
    if let parent = parentToolCallId {
      var bucket = turn.subagents[parent] ?? SubagentTranscript()
      bucket.isThinking = true
      turn.subagents[parent] = bucket
    } else {
      turn.isThinking = true
    }
  }

  static func finalizeAssistant(
    markdown: String,
    messageId: String?,
    attachments: [Attachment],
    to turn: inout AssistantTurn
  ) {
    turn.isThinking = false
    turn.attachments = attachments
    let identified = messageId.flatMap { textIndex("acp:\($0)", in: turn.entries) }
    if let index = identified ?? turn.finalTextIndex,
      case let .text(id, _) = turn.entries[index]
    {
      turn.entries[index] = .text(id: id, markdown: markdown)
      return
    }
    guard !markdown.isEmpty else { return }
    let id: String
    if let messageId {
      id = "acp:\(messageId)"
    } else {
      id = "t\(turn.nextTextId)"
      turn.nextTextId += 1
    }
    turn.entries.append(.text(id: id, markdown: markdown))
  }

  private static func text(from block: ContentBlock) -> String {
    block.textValue ?? ""
  }

  /// Appends streamed text. ACP `messageId` is the semantic boundary between
  /// assistant messages, so it wins over adjacency when present. Returns the
  /// id of the text entry the chunk addressed — for zero-length chunks with a
  /// messageId that's the (possibly not yet created) span the chunk's phase
  /// retro-tags; without one there is nothing to address.
  @discardableResult
  private static func appendText(
    _ newText: String,
    messageId: String?,
    entries: inout [TranscriptEntry],
    nextTextId: inout Int
  ) -> String? {
    if let messageId {
      return appendAddressed(newText, messageId: messageId, entries: &entries)
    }
    return appendAdjacent(newText, entries: &entries, nextTextId: &nextTextId)
  }

  private static func appendAddressed(_ newText: String, messageId: String, entries: inout [TranscriptEntry]) -> String
  {
    let id = "acp:\(messageId)"
    guard !newText.isEmpty else { return id }
    if let index = textIndex(id, in: entries) {
      appendInPlace(newText, toTextEntryAt: index, in: &entries)
    } else {
      entries.append(.text(id: id, markdown: newText))
    }
    return id
  }

  private static func appendAdjacent(
    _ newText: String, entries: inout [TranscriptEntry], nextTextId: inout Int
  ) -> String? {
    guard !newText.isEmpty else { return nil }
    if case let .text(id, _) = entries.last {
      appendInPlace(newText, toTextEntryAt: entries.count - 1, in: &entries)
      return id
    } else {
      let id = "t\(nextTextId)"
      nextTextId += 1
      entries.append(.text(id: id, markdown: newText))
      return id
    }
  }

  /// Appends to a text entry without copying the accumulated run.
  /// `existing + newText` re-copies everything streamed so far on every
  /// flush — O(turn²) over a long answer. Taking the string out of the
  /// entry first makes its storage uniquely referenced, so `+=` extends it
  /// in place at amortized O(newText).
  private static func appendInPlace(
    _ newText: String,
    toTextEntryAt index: Int,
    in entries: inout [TranscriptEntry]
  ) {
    guard case .text(let id, var existing) = entries[index] else { return }
    entries[index] = .text(id: id, markdown: "")
    existing += newText
    entries[index] = .text(id: id, markdown: existing)
  }

  private static func textIndex(_ id: String, in entries: [TranscriptEntry]) -> Int? {
    entries.firstIndex {
      if case let .text(existingId, _) = $0 { return existingId == id }
      return false
    }
  }

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
      appendOverlap(patch, length: length, existing: &existing)
    }
    writeSpan(id: id, index: index, existing: existing, entries: &entries)
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

  private static func appendOverlap(_ patch: AgentMessagePatch, length: Int, existing: inout String) {
    let overlap = length - patch.offset
    let incoming = patch.text as NSString
    if overlap < incoming.length {
      existing += incoming.substring(from: overlap)
    }
  }

  private static func writeSpan(id: String, index: Int?, existing: String, entries: inout [TranscriptEntry]) {
    if let index {
      entries[index] = .text(id: id, markdown: existing)
    } else if !existing.isEmpty {
      // A zero-length span contributes no content and shifts no later
      // offset, so it is never materialized. Whitespace-only spans DO carry
      // length that subsequent patch offsets are measured against, so they
      // are stored and filtered at presentation (`isBlankText`) instead.
      entries.append(.text(id: id, markdown: existing))
    }
  }
}
