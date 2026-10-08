import ACPKit
import Foundation

enum TranscriptToolReduction {
  static func applyCall(_ call: ToolCall, to turn: inout AssistantTurn) {
    if let position = call.statePosition { turn.entryPositions["tool:\(call.toolCallId)"] = position }
    if let parent = call.parentToolCallId {
      turn.entries.removeAll { $0.id == "tool:\(call.toolCallId)" }
      var bucket = turn.subagents[parent] ?? SubagentTranscript()
      bucket.isThinking = false
      upsertTool(call, entries: &bucket.entries)
      turn.subagents[parent] = bucket
    } else {
      turn.isThinking = false
      upsertTool(call, entries: &turn.entries)
      turn.receiveGeneratedImage(call)
    }
    // An agent call gets its bucket eagerly so the UI can render the
    // nested section before any child output arrives.
    cascadeSettleIfParent(ToolCallUpdate(toolCallId: call.toolCallId, status: call.status), in: &turn)
    if call.kind == .agent, turn.subagents[call.toolCallId] == nil {
      turn.subagents[call.toolCallId] = SubagentTranscript()
    }
  }

  static func applyQuestion(_ resolution: QuestionResolution, to turn: inout AssistantTurn) {
    // An answered question renders as a normal tool-call row, inline in
    // the arrival position it resolved. `upsertTool` dedupes by id, so
    // replay redelivering the pair is idempotent.
    turn.isThinking = false
    let call = syntheticQuestionCall(for: resolution)
    if let position = resolution.statePosition { turn.entryPositions["tool:\(call.toolCallId)"] = position }
    upsertTool(call, entries: &turn.entries)
  }

  private static func toolIndex(_ toolCallId: String, in entries: [TranscriptEntry]) -> Int? {
    entries.firstIndex {
      if case let .tool(call) = $0 { return call.toolCallId == toolCallId }
      return false
    }
  }

  private static func upsertTool(_ call: ToolCall, entries: inout [TranscriptEntry]) {
    if let index = toolIndex(call.toolCallId, in: entries), case let .tool(existing) = entries[index] {
      if let revision = call.stateRevision, revision < (existing.stateRevision ?? 0) { return }
      if call.isSnapshot == true { entries[index] = .tool(call); return }
      // A full re-send replaces the call, but must not clobber streamed
      // state it omits (diffStats/content arrive on separate updates).
      var merged = call
      mergeOmittedDetails(into: &merged, from: existing)
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
    let title = questionTitle(questions)
    let body = questionBody(questions, in: resolution)
    return ToolCall(
      toolCallId: "question:\(resolution.questionId)",
      title: title,
      kind: .question,
      status: .completed,
      content: body.isEmpty ? nil : [.content(.text(body))]
    )
  }

  /// The chosen answer text for one sub-question: the selected option
  /// label(s), then any free-form note on its own labelled line so it never
  /// reads as another selected option; "No answer" when nothing was given.
  private static func answerText(for question: QuestionSpec, in resolution: QuestionResolution) -> String {
    guard let entry = resolution.answers?[question.id] else { return "No answer" }
    // Text with no selected option is the answer itself (macOS sends an
    // "Other" reply this way), not a note on one.
    if entry.answers.isEmpty, let note = entry.note, !note.isEmpty { return note }
    let note = entry.note.flatMap { $0.isEmpty ? nil : "Note: \($0)" }
    let lines = [entry.answers.isEmpty ? nil : entry.answers.joined(separator: ", "), note].compactMap(\.self)
    return lines.isEmpty ? "No answer" : lines.joined(separator: "\n")
  }

  /// Routes a tool-call update by id lookup — main entries first, then every
  /// subagent thread — because settle updates (tool results, interrupt
  /// force-settles) do not carry `parentToolCallId`. Unknown ids fall back to
  /// the update's own parent attribution, then to the main list.
  static func applyToolUpdate(_ update: ToolCallUpdate, to turn: inout AssistantTurn) {
    if applyMainUpdate(update, to: &turn) { return }
    for key in turn.subagents.keys {
      guard var bucket = turn.subagents[key],
        let index = toolIndex(update.toolCallId, in: bucket.entries),
        case let .tool(existing) = bucket.entries[index]
      else { continue }
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
      turn.receiveGeneratedImage(update.asToolCall())
    }
  }

  /// When the settled call is itself a subagent parent, its children must
  /// not keep spinning: settle the whole nested thread (and any threads
  /// nested below it) with the parent's outcome.
  private static func cascadeSettleIfParent(_ update: ToolCallUpdate, in turn: inout AssistantTurn) {
    guard let status = update.status,
      let outcome = outcome(for: status),
      turn.subagents[update.toolCallId] != nil
    else { return }
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

  private static func outcome(for status: ToolCallStatus) -> TranscriptReducer.TurnOutcome? {
    switch status {
    case .completed: return .completed
    case .failed: return .failed
    case .cancelled: return .cancelled
    case .pending, .inProgress: return nil
    }
  }

  /// Marks every non-terminal tool call in the turn — including those inside
  /// subagent threads — with the outcome's terminal status, so in-progress
  /// indicators can never outlive the turn.
  static func settleToolCalls(_ turn: inout AssistantTurn, outcome: TranscriptReducer.TurnOutcome) {
    settle(entries: &turn.entries, outcome: outcome)
    for key in turn.subagents.keys {
      guard var bucket = turn.subagents[key] else { continue }
      bucket.isThinking = false
      settle(entries: &bucket.entries, outcome: outcome)
      turn.subagents[key] = bucket
    }
  }

  private static func settle(entries: inout [TranscriptEntry], outcome: TranscriptReducer.TurnOutcome) {
    for index in entries.indices {
      guard case var .tool(call) = entries[index], !call.isSettled else { continue }
      call.status =
        switch outcome {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
      entries[index] = .tool(call)
    }
  }

  private static func mergeOmittedDetails(into merged: inout ToolCall, from existing: ToolCall) {
    if merged.diffStats == nil { merged.diffStats = existing.diffStats }
    if merged.content == nil { merged.content = existing.content }
    if merged.rawInput == nil { merged.rawInput = existing.rawInput }
    if merged.rawOutput == nil { merged.rawOutput = existing.rawOutput }
    if merged.exitCode == nil { merged.exitCode = existing.exitCode }
    if merged.meta == nil { merged.meta = existing.meta }
  }

  private static func applyMainUpdate(_ update: ToolCallUpdate, to turn: inout AssistantTurn) -> Bool {
    if let index = toolIndex(update.toolCallId, in: turn.entries),
      case let .tool(existing) = turn.entries[index]
    {
      turn.isThinking = false
      let call = existing.applying(update)
      turn.entries[index] = .tool(call)
      turn.receiveGeneratedImage(call)
      cascadeSettleIfParent(update, in: &turn)
      return true
    }
    return false
  }

  private static func questionTitle(_ questions: [QuestionSpec]) -> String {
    let title: String
    switch questions.count {
    case 1: title = questions[0].question
    case 0: title = "Answered a question"
    default: title = "Answered \(questions.count) questions"
    }
    return title
  }

  private static func questionBody(_ questions: [QuestionSpec], in resolution: QuestionResolution) -> String {
    let body: String
    if questions.count == 1 {
      body = answerText(for: questions[0], in: resolution)
    } else {
      body =
        questions
        .map { "\($0.question)\n\(answerText(for: $0, in: resolution))" }
        .joined(separator: "\n\n")
    }
    return body
  }
}
