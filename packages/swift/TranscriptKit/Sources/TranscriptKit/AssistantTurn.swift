import Foundation
import ACPKit

/// The streamed thread of one subagent (text spans and tool calls), nested
/// under the parent tool call that spawned it. Same shape as a turn's entries,
/// which is what lets the UI render it with the same transcript components.
public struct SubagentTranscript: Sendable, Equatable {
  public var entries: [TranscriptEntry]
  public var isThinking: Bool
  /// Monotonic counter used to give each new text span a stable id.
  public var nextTextId: Int

  public init(entries: [TranscriptEntry] = [], isThinking: Bool = false, nextTextId: Int = 0) {
    self.entries = entries
    self.isThinking = isThinking
    self.nextTextId = nextTextId
  }
}

/// Status of an in-flight transient retry (e.g. a 529 overload being retried).
/// Progress is optional because some harnesses only announce reconnection.
public struct RetryStatus: Sendable, Equatable {
  public let attempt: Int?
  public let of: Int?
  public let message: String
  public init(attempt: Int? = nil, of: Int? = nil, message: String = "Server is busy, reconnecting") {
    self.attempt = attempt
    self.of = of
    self.message = message
  }
}

/// The streaming state of one assistant response.
public struct AssistantTurn: Sendable, Equatable {
  public var entries: [TranscriptEntry]
  /// Immutable files delivered by the assistant, including generated images
  /// that arrive while the turn is still running.
  public var attachments: [Attachment]
  public var isGenerating: Bool
  public var isThinking: Bool
  public var stopReason: StopReason?
  /// A short human-readable reason the turn ended abnormally (error / limit /
  /// refusal / gave-up truncation), set by the provider. `nil` for a clean
  /// completion or a silently-recovered turn; when present it renders as a
  /// per-turn line so a non-clean stop is never silent.
  public var stopDetail: String?
  /// Machine-readable end classification from the provider ("usageLimit"
  /// today); nil means unclassified. Lets the UI offer the RIGHT action —
  /// switch accounts — instead of only prose.
  public var stopKind: String?
  /// True when the provider exhausted automatic retries and the original
  /// prompt can safely be submitted again by the user.
  public var retryable: Bool
  /// Set while a transient failure is being retried; drives the visible
  /// "Retrying…" status. Cleared once new content streams or the turn ends.
  public var retryStatus: RetryStatus?
  public var plan: Plan?
  /// A proposed plan document (markdown) from plan mode — distinct from the
  /// step checklist in `plan`. Replaced wholesale per update.
  public var planDocument: String?
  public var planResource: ToolDetailResource? = nil
  public var planRevision: Int = 0
  /// The `entries` count at the moment the plan document was (last) proposed.
  /// Splits the worked section into planning (before) and the implementation
  /// that follows approval (after), so the latter renders below the plan card
  /// instead of above it. nil when the turn produced no plan.
  public var planBoundary: Int?
  /// When the latest plan document was proposed: the end of the planning
  /// "Worked for…" section. Server-durable; stamped locally while live.
  public var planProposedAt: Date? = nil
  /// When the user answered the plan and this same turn resumed working
  /// (Claude continues the turn after ExitPlanMode): the start of the section
  /// below the plan. The wait for the user belongs to neither section.
  public var planResumedAt: Date? = nil
  public var startedAt: Date?
  public var endedAt: Date?
  /// Nested subagent threads, keyed by the parent (Task/agent) tool call id.
  /// Deliberately flat: a subagent's own agent calls key their buckets here
  /// too, so the UI recurses by lookup instead of by structure.
  public var subagents: [String: SubagentTranscript]
  /// Provider-asserted finality per text entry id. `commentary` spans never
  /// become the final answer; `final` spans are it with certainty; absent
  /// means unknown (the last text span is the optimistic candidate). Fed by
  /// chunk `phase` — codex tags whole messages, Claude retro-tags preamble
  /// once a tool call proves it wasn't the answer.
  public var textPhases: [String: MessagePhase]
  public var entryPositions: [String: Int] = [:]
  public var textStates: [String: TranscriptTextState] = [:]
  /// Server transcript item whose hidden worked details have not been fetched
  /// yet. Summary/final text renders immediately; expansion hydrates only this
  /// turn's bounded event set.
  public var deferredDetailItemId: String?
  public var hasDeferredWorkedDetails: Bool
  public var detailRevision: Int
  /// True after deferred worked details were restored from durable history.
  /// Renderers use this provenance to settle the restored text even when the
  /// owning turn is still generating; later live entries remain animated.
  public var hasHydratedWorkedDetails: Bool
  /// Monotonic counter used to give each new text span a stable id.
  public var nextTextId: Int

  public init(
    entries: [TranscriptEntry] = [],
    attachments: [Attachment] = [],
    isGenerating: Bool = false,
    isThinking: Bool = false,
    stopReason: StopReason? = nil,
    stopDetail: String? = nil,
    stopKind: String? = nil,
    retryable: Bool = false,
    retryStatus: RetryStatus? = nil,
    plan: Plan? = nil,
    planDocument: String? = nil,
    planBoundary: Int? = nil,
    startedAt: Date? = nil,
    endedAt: Date? = nil,
    subagents: [String: SubagentTranscript] = [:],
    textPhases: [String: MessagePhase] = [:],
    deferredDetailItemId: String? = nil,
    hasDeferredWorkedDetails: Bool = false,
    detailRevision: Int = 0,
    hasHydratedWorkedDetails: Bool = false,
    nextTextId: Int = 0
  ) {
    self.entries = entries
    self.attachments = attachments
    self.isGenerating = isGenerating
    self.isThinking = isThinking
    self.stopReason = stopReason
    self.stopDetail = stopDetail
    self.stopKind = stopKind
    self.retryable = retryable
    self.retryStatus = retryStatus
    self.plan = plan
    self.planDocument = planDocument
    self.planBoundary = planBoundary
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.subagents = subagents
    self.textPhases = textPhases
    self.deferredDetailItemId = deferredDetailItemId
    self.hasDeferredWorkedDetails = hasDeferredWorkedDetails
    self.detailRevision = detailRevision
    self.hasHydratedWorkedDetails = hasHydratedWorkedDetails
    self.nextTextId = nextTextId
  }

  /// Latest context-compaction lifecycle, used only for the temporary
  /// turn-level activity indicator. Completed compaction is not visible work.
  public var contextCompactionStatus: ContextCompactionStatus? {
    for entry in entries.reversed() {
      if case let .contextCompaction(_, status) = entry { return status }
    }
    return nil
  }

  /// The last assistant text message, rendered expanded at the bottom as the final answer.
  ///
  /// ACP agents may interleave tool calls after chunks for the final message.
  /// Treating "physically last entry" as final hides valid answers in that shape.
  /// Spans phase-tagged `commentary` (codex harmony channels, Claude preamble
  /// demotion) are never the answer — while streaming, this is what lets the
  /// live candidate render final-styled from its first chunk and demote the
  /// moment a provider proves it was narration.
  public var finalText: TranscriptEntry? {
    guard let index = finalTextIndex else { return nil }
    return entries[index]
  }

  /// True when the current final-answer candidate is provider-asserted
  /// (phase `final`, e.g. codex harmony channels) rather than optimistic.
  /// Certainty the answer is underway: the UI can settle the worked section
  /// as soon as this text starts streaming instead of waiting for turn end.
  public var finalTextIsAsserted: Bool {
    guard case let .text(id, _) = finalText else { return false }
    return textPhases[id] == .final
  }

  /// Everything except the final answer — intermediate text and all tool
  /// calls — collapsed into the "Worked for…" disclosure.
  public var workedEntries: [TranscriptEntry] {
    let finalID = finalText?.id
    return entries.compactMap { entry in
      if entry.id == finalID { return nil }
      if case .contextCompaction = entry { return nil }
      if case let .tool(call) = entry, call.kind == .imageGeneration { return nil }
      return entry
    }
  }

  /// The tool calls within this turn, in order.
  public var toolCalls: [ToolCall] {
    entries.compactMap { if case let .tool(call) = $0 { return call } else { return nil } }
  }

  /// A top-level tool call that has started but not yet settled. Its card
  /// renders its own running shimmer, so the turn-level activity indicator
  /// defers to it (an in-progress Agent tool stays unsettled while its
  /// subagent runs, which is what keeps this true for background work).
  public var hasRunningToolCall: Bool {
    toolCalls.contains { !$0.isSettled }
  }

  /// Whether the ephemeral "Thinking…" activity indicator should show for the
  /// top-level thread. The turn is generating but nothing concrete is
  /// streaming right now — the gap between steps (waiting on the model to
  /// respond, or a tool call to start) where the transcript would otherwise
  /// look frozen.
  ///
  /// `isThinking` (an explicit thought-token stream) always qualifies. Absent
  /// that, the indicator shows unless there is already visible activity: the
  /// final answer actively streaming (`finalText` present), or a tool call in
  /// progress — each renders its own affordance, so a second indicator would
  /// be redundant. This is deliberately broader than `isThinking`, which is a
  /// knife-edge signal cleared by the first non-thought chunk and only ever
  /// re-armed by another thought chunk (so harnesses that don't stream
  /// thinking, or any lull between tool calls, would otherwise show nothing).
  public var showsActivityIndicator: Bool {
    guard isGenerating else { return false }
    if isThinking { return true }
    return finalText == nil && !hasRunningToolCall
  }

  /// Whether the transcript keeps the activity indicator's row laid out even
  /// while the indicator itself is hidden. Tool calls toggle
  /// `showsActivityIndicator` on every start and finish; removing the row
  /// each time bounced the bottom-pinned transcript. The slot holds from the
  /// start of work until the answer (or a preamble span) streams, where the
  /// text's own growth absorbs the one-time removal.
  public var reservesActivitySlot: Bool {
    guard isGenerating else { return false }
    return showsActivityIndicator || finalText == nil
  }

  /// Every tool call in the turn, including those inside subagent threads —
  /// the membership check for routing late updates into a finished turn.
  public var allToolCalls: [ToolCall] {
    toolCalls
      + subagents.keys.sorted().flatMap { key in
        (subagents[key]?.entries ?? []).compactMap {
          if case let .tool(call) = $0 { return call } else { return nil }
        }
      }
  }

  /// Whether this turn started the current run of a running subagent: it
  /// holds the call named in `runToolCallIds` — the spawn for a first run, the
  /// message sent to the agent for a later one. Only that turn keeps its
  /// worked section open; the turn that first spawned an agent doesn't
  /// reopen each time the agent is messaged again.
  public func startedRunningSubagent(_ runToolCallIds: Set<String>) -> Bool {
    guard !runToolCallIds.isEmpty else { return false }
    func holds(_ entries: [TranscriptEntry]) -> Bool {
      entries.contains { entry in
        if case let .tool(call) = entry { return runToolCallIds.contains(call.toolCallId) }
        return false
      }
    }
    return holds(entries) || subagents.values.contains { holds($0.entries) }
  }

  /// Cheap change signal for streaming subagent activity, folded into the
  /// scroll-follow fingerprint so nested output keeps the view pinned.
  public var subagentActivityFingerprint: Int {
    var hasher = Hasher()
    for key in subagents.keys.sorted() {
      guard let bucket = subagents[key] else { continue }
      hasher.combine(key)
      hasher.combine(bucket.entries.count)
      hasher.combine(bucket.isThinking)
      if case let .text(_, markdown) = bucket.entries.last {
        // utf8.count is O(1); `count` walks every grapheme cluster —
        // and this recomputes every flush while a subagent streams.
        hasher.combine(markdown.utf8.count)
      }
    }
    return hasher.finalize()
  }

  /// Wall-clock duration of the turn, once finished.
  public var duration: TimeInterval? {
    guard let startedAt, let endedAt else { return nil }
    return max(0, endedAt.timeIntervalSince(startedAt))
  }

  /// Index of the final-answer text span, excluded from the worked sections
  /// (it renders expanded below). Internal so the worked-section splitting in
  /// `WorkedItems` can drop it from either slice.
  public var finalTextIndex: Int? {
    entries.indices.reversed().first { index in
      let entry = entries[index]
      guard case let .text(id, _) = entry, !entry.isBlankText else { return false }
      return textPhases[id] != .commentary
    }
  }
}
