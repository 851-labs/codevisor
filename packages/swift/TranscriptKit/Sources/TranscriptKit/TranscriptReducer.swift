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
    defer { orderEntries(&turn) }
    let parent: String?
    switch update {
    case let .agentMessagePatch(patch): parent = patch.parentToolCallId
    case let .toolCall(call): parent = call.parentToolCallId
    default: parent = nil
    }
    if let parent, !turn.allToolCalls.contains(where: { $0.toolCallId == parent }) {
      turn.entries.append(
        .tool(
          ToolCall(
            toolCallId: parent, title: "Subagent", kind: .agent,
            status: turn.isGenerating ? .inProgress : .completed)))
    }
    switch update {
    case let .agentMessagePatch(patch):
      TranscriptTextReduction.applyTextPatch(patch, to: &turn)

    case let .agentMessageChunk(block, messageId, parentToolCallId, phase):
      TranscriptTextReduction.applyChunk(
        block, messageId: messageId, parentToolCallId: parentToolCallId, phase: phase, to: &turn)

    case let .agentThoughtChunk(_, _, parentToolCallId):
      TranscriptTextReduction.applyThought(parentToolCallId: parentToolCallId, to: &turn)

    case .userMessageChunk(_, _):
      break  // Echo of the user's own input.

    case let .toolCall(call):
      TranscriptToolReduction.applyCall(call, to: &turn)

    case let .toolCallUpdate(update):
      TranscriptToolReduction.applyToolUpdate(update, to: &turn)

    case let .plan(plan):
      turn.plan = plan

    case let .planDocument(markdown, resource, revision):
      guard (revision ?? 0) >= turn.planRevision else { break }
      turn.planRevision = revision ?? 0
      turn.planResource = resource
      turn.isThinking = false
      turn.planDocument = markdown
      // Mark where the plan landed in the stream so the work that follows
      // approval renders below the plan card, not folded in above it.
      turn.planBoundary = turn.entries.count

    case let .contextCompaction(id, status):
      turn.isThinking = false
      TranscriptEntryOrdering.applyContextCompaction(id: id, status: status, entries: &turn.entries)

    case let .questionResolved(resolution):
      TranscriptToolReduction.applyQuestion(resolution, to: &turn)

    case .question, .availableCommandsUpdate, .availableSkillsUpdate, .currentModeUpdate,
      .configOptionUpdate, .usageUpdate, .goalUpdate, .goalCleared:
      // Session-level state; handled by SessionModel, not the transcript.
      break
    }
  }

  /// Replaces the streamed final span with the server's durable artifact-aware
  /// Markdown and associates the promoted files with the turn. This is a
  /// replacement, not another chunk, so reconnect and live delivery converge.
  public static func finalizeAssistant(
    markdown: String,
    messageId: String?,
    attachments: [Attachment],
    to turn: inout AssistantTurn
  ) {
    TranscriptTextReduction.finalizeAssistant(
      markdown: markdown, messageId: messageId, attachments: attachments, to: &turn)
  }

  public static func orderEntries(_ turn: inout AssistantTurn) {
    TranscriptEntryOrdering.orderEntries(&turn)
  }

  /// How a turn reached its end, for settling tool calls that never received
  /// a terminal status of their own.
  public enum TurnOutcome: Sendable, Equatable {
    case completed, cancelled, failed
  }

  /// Marks every non-terminal tool call in the turn — including those inside
  /// subagent threads — with the outcome's terminal status, so in-progress
  /// indicators can never outlive the turn.
  public static func settleToolCalls(_ turn: inout AssistantTurn, outcome: TurnOutcome) {
    TranscriptToolReduction.settleToolCalls(&turn, outcome: outcome)
  }
}

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
