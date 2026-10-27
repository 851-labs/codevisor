import Foundation
import ACPKit

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
      break

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
      turn.planBoundary = turn.entries.count

    case let .contextCompaction(id, status):
      turn.isThinking = false
      TranscriptEntryOrdering.applyContextCompaction(id: id, status: status, entries: &turn.entries)

    case let .question(request):
      applyQuestion(request, to: &turn)

    case let .questionResolved(resolution):
      applyResolution(resolution, to: &turn)

    case .availableCommandsUpdate, .availableSkillsUpdate, .currentModeUpdate,
      .configOptionUpdate, .usageUpdate, .goalUpdate, .goalCleared:
      break
    }
  }

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

  public enum TurnOutcome: Sendable, Equatable {
    case completed, cancelled, failed
  }

  public static func settleToolCalls(_ turn: inout AssistantTurn, outcome: TurnOutcome) {
    TranscriptToolReduction.settleToolCalls(&turn, outcome: outcome)
  }

  private static func applyQuestion(_ request: QuestionRequest, to turn: inout AssistantTurn) {
    if let kind = TranscriptSetupRequest.kind(of: request.questions) {
      turn.isThinking = false
      turn.addSetupRequest(.init(id: request.questionId, kind: kind, state: .pending))
    } else if TranscriptQuestion.asksInTranscript(request.questions) {
      turn.isThinking = false
      turn.interactions.ask(request)
    }
  }

  private static func applyResolution(_ resolution: QuestionResolution, to turn: inout AssistantTurn) {
    if let kind = TranscriptSetupRequest.kind(of: resolution.questions) {
      let state: TranscriptSetupRequest.State = resolution.outcome == .cancelled ? .declined : .setUp
      turn.upsertSetupRequest(.init(id: resolution.questionId, kind: kind, state: state))
    } else if TranscriptQuestion.asksInTranscript(resolution.questions) {
      turn.interactions.resolve(resolution)
    } else {
      TranscriptToolReduction.applyQuestion(resolution, to: &turn)
    }
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
