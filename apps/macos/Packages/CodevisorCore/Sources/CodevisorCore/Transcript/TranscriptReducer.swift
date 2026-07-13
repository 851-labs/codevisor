import Foundation
import ACPKit

/// Applies streamed `SessionUpdate`s to an `AssistantTurn`, preserving arrival
/// order and merging tool-call updates. Pure and synchronous so it is trivially
/// unit-testable; the view model wraps it with the async update stream.
///
/// Updates carrying a `parentToolCallId` belong to a subagent's thread and are
/// routed into `turn.subagents[parent]` instead of the main entry list; they
/// never affect the main turn's thinking state.
public enum TranscriptReducer {
    public static func apply(_ update: SessionUpdate, to turn: inout AssistantTurn) {
        switch update {
        case let .agentMessageChunk(block, messageId, parentToolCallId, phase):
            if let parent = parentToolCallId {
                var bucket = turn.subagents[parent] ?? SubagentTranscript()
                bucket.isThinking = false
                appendText(text(from: block), messageId: messageId, entries: &bucket.entries, nextTextId: &bucket.nextTextId)
                turn.subagents[parent] = bucket
            } else {
                turn.isThinking = false
                let entryId = appendText(text(from: block), messageId: messageId, entries: &turn.entries, nextTextId: &turn.nextTextId)
                // Finality rides per chunk (codex tags whole messages) or as a
                // zero-length retro-tag (Claude demoting streamed preamble once
                // a tool call starts). Keyed by entry id so `finalText` can
                // skip commentary spans; subagent threads never split a final
                // answer out, so phases are main-thread only.
                if let phase, let entryId {
                    turn.textPhases[entryId] = phase
                }
            }

        case let .agentThoughtChunk(_, _, parentToolCallId):
            // Thoughts surface only as the ephemeral "Thinking…" indicator; they
            // are not persisted as transcript entries.
            if let parent = parentToolCallId {
                var bucket = turn.subagents[parent] ?? SubagentTranscript()
                bucket.isThinking = true
                turn.subagents[parent] = bucket
            } else {
                turn.isThinking = true
            }

        case .userMessageChunk(_, _):
            break // Echo of the user's own input.

        case let .toolCall(call):
            if let parent = call.parentToolCallId {
                var bucket = turn.subagents[parent] ?? SubagentTranscript()
                bucket.isThinking = false
                upsertTool(call, entries: &bucket.entries)
                turn.subagents[parent] = bucket
            } else {
                turn.isThinking = false
                upsertTool(call, entries: &turn.entries)
            }
            // An agent call gets its bucket eagerly so the UI can render the
            // nested section before any child output arrives.
            if call.kind == .agent, turn.subagents[call.toolCallId] == nil {
                turn.subagents[call.toolCallId] = SubagentTranscript()
            }

        case let .toolCallUpdate(update):
            applyToolUpdate(update, to: &turn)

        case let .plan(plan):
            turn.plan = plan

        case let .planDocument(markdown):
            turn.isThinking = false
            turn.planDocument = markdown
            // Mark where the plan landed in the stream so the work that follows
            // approval renders below the plan card, not folded in above it.
            turn.planBoundary = turn.entries.count

        case let .questionResolved(resolution):
            // An answered question renders as a normal tool-call row, inline in
            // the arrival position it resolved. `upsertTool` dedupes by id, so
            // replay redelivering the pair is idempotent.
            turn.isThinking = false
            upsertTool(syntheticQuestionCall(for: resolution), entries: &turn.entries)

        case .question, .availableCommandsUpdate, .currentModeUpdate, .configOptionUpdate,
             .usageUpdate, .goalUpdate, .goalCleared:
            // Session-level state; handled by SessionModel, not the transcript.
            break
        }
    }

    // MARK: - Helpers

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
            let id = "acp:\(messageId)"
            guard !newText.isEmpty else { return id }
            if let index = textIndex(id, in: entries) {
                if case let .text(_, existing) = entries[index] {
                    entries[index] = .text(id: id, markdown: existing + newText)
                }
            } else {
                entries.append(.text(id: id, markdown: newText))
            }
            return id
        }

        guard !newText.isEmpty else { return nil }
        if case let .text(id, existing) = entries.last {
            entries[entries.count - 1] = .text(id: id, markdown: existing + newText)
            return id
        } else {
            let id = "t\(nextTextId)"
            nextTextId += 1
            entries.append(.text(id: id, markdown: newText))
            return id
        }
    }

    private static func textIndex(_ id: String, in entries: [TranscriptEntry]) -> Int? {
        entries.firstIndex {
            if case let .text(existingId, _) = $0 { return existingId == id }
            return false
        }
    }

    private static func toolIndex(_ toolCallId: String, in entries: [TranscriptEntry]) -> Int? {
        entries.firstIndex {
            if case let .tool(call) = $0 { return call.toolCallId == toolCallId }
            return false
        }
    }

    private static func upsertTool(_ call: ToolCall, entries: inout [TranscriptEntry]) {
        if let index = toolIndex(call.toolCallId, in: entries), case let .tool(existing) = entries[index] {
            // A full re-send replaces the call, but must not clobber streamed
            // state it omits (diffStats/content arrive on separate updates).
            var merged = call
            if merged.diffStats == nil { merged.diffStats = existing.diffStats }
            if merged.content == nil { merged.content = existing.content }
            entries[index] = .tool(merged)
        } else {
            entries.append(.tool(call))
        }
    }

    /// Synthesizes the tool call that stands in for an answered question, so it
    /// flows through the same grouping/rendering path as every other tool call.
    /// The id is derived from the question id so replays upsert in place. The
    /// row title is the question itself (single) or a count (multiple); the
    /// expandable content carries the chosen answer(s).
    private static func syntheticQuestionCall(for resolution: QuestionResolution) -> ToolCall {
        let questions = resolution.questions
        let title: String
        switch questions.count {
        case 1: title = questions[0].question
        case 0: title = "Answered a question"
        default: title = "Answered \(questions.count) questions"
        }
        let body: String
        if questions.count == 1 {
            body = answerText(for: questions[0], in: resolution)
        } else {
            body = questions
                .map { "\($0.question)\n\(answerText(for: $0, in: resolution))" }
                .joined(separator: "\n\n")
        }
        return ToolCall(
            toolCallId: "question:\(resolution.questionId)",
            title: title,
            kind: .question,
            status: .completed,
            content: body.isEmpty ? nil : [.content(.text(body))]
        )
    }

    /// The chosen answer text for one sub-question: the selected option
    /// label(s) plus any free-form note, or "No answer" when nothing was picked.
    private static func answerText(for question: QuestionSpec, in resolution: QuestionResolution) -> String {
        guard let entry = resolution.answers?[question.id] else { return "No answer" }
        var parts = entry.answers
        if let note = entry.note, !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? "No answer" : parts.joined(separator: ", ")
    }

    /// Routes a tool-call update by id lookup — main entries first, then every
    /// subagent thread — because settle updates (tool results, interrupt
    /// force-settles) do not carry `parentToolCallId`. Unknown ids fall back to
    /// the update's own parent attribution, then to the main list.
    private static func applyToolUpdate(_ update: ToolCallUpdate, to turn: inout AssistantTurn) {
        if let index = toolIndex(update.toolCallId, in: turn.entries),
           case let .tool(existing) = turn.entries[index] {
            turn.isThinking = false
            turn.entries[index] = .tool(existing.applying(update))
            cascadeSettleIfParent(update, in: &turn)
            return
        }
        for key in turn.subagents.keys {
            guard var bucket = turn.subagents[key],
                  let index = toolIndex(update.toolCallId, in: bucket.entries),
                  case let .tool(existing) = bucket.entries[index] else { continue }
            bucket.entries[index] = .tool(existing.applying(update))
            turn.subagents[key] = bucket
            cascadeSettleIfParent(update, in: &turn)
            return
        }
        if let parent = update.parentToolCallId {
            var bucket = turn.subagents[parent] ?? SubagentTranscript()
            bucket.entries.append(.tool(update.asToolCall()))
            turn.subagents[parent] = bucket
        } else {
            turn.isThinking = false
            turn.entries.append(.tool(update.asToolCall()))
        }
    }

    /// When the settled call is itself a subagent parent, its children must
    /// not keep spinning: settle the whole nested thread (and any threads
    /// nested below it) with the parent's outcome.
    private static func cascadeSettleIfParent(_ update: ToolCallUpdate, in turn: inout AssistantTurn) {
        guard let status = update.status,
              let outcome = outcome(for: status),
              turn.subagents[update.toolCallId] != nil else { return }
        var queue = [update.toolCallId]
        var visited: Set<String> = []
        while let id = queue.popLast() {
            guard visited.insert(id).inserted, var bucket = turn.subagents[id] else { continue }
            bucket.isThinking = false
            settle(entries: &bucket.entries, outcome: outcome)
            turn.subagents[id] = bucket
            for case let .tool(call) in bucket.entries where turn.subagents[call.toolCallId] != nil {
                queue.append(call.toolCallId)
            }
        }
    }

    private static func outcome(for status: ToolCallStatus) -> TurnOutcome? {
        switch status {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .pending, .inProgress: return nil
        }
    }

    // MARK: - Turn settling

    /// How a turn reached its end, for settling tool calls that never received
    /// a terminal status of their own.
    public enum TurnOutcome: Sendable, Equatable {
        case completed, cancelled, failed
    }

    /// Marks every non-terminal tool call in the turn — including those inside
    /// subagent threads — with the outcome's terminal status, so in-progress
    /// indicators can never outlive the turn.
    public static func settleToolCalls(_ turn: inout AssistantTurn, outcome: TurnOutcome) {
        settle(entries: &turn.entries, outcome: outcome)
        for key in turn.subagents.keys {
            guard var bucket = turn.subagents[key] else { continue }
            bucket.isThinking = false
            settle(entries: &bucket.entries, outcome: outcome)
            turn.subagents[key] = bucket
        }
    }

    private static func settle(entries: inout [TranscriptEntry], outcome: TurnOutcome) {
        for index in entries.indices {
            guard case var .tool(call) = entries[index], !call.isSettled else { continue }
            call.status = switch outcome {
            case .completed: .completed
            case .cancelled: .cancelled
            case .failed: .failed
            }
            entries[index] = .tool(call)
        }
    }
}
