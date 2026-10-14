import ACPKit
import Foundation
import TranscriptKit

@MainActor
enum SubagentThreadCollector {
  enum Piece: Equatable {
    case followUp(key: String, text: String?, position: Int?)
    case work(TranscriptEntry, position: Int?, runId: String, turn: AssistantTurn)

    var position: Int? {
      switch self {
      case let .followUp(_, _, position), let .work(_, position, _, _): position
      }
    }
  }

  struct Thread: Equatable {
    var spawn: ToolCall?
    var spawnMessageId: UUID?
    var prompt: String?
    var runIds: [String] = []
    var latestRun: ToolCall?
    var isMissingEarlierRuns = false
    var pieces: [Piece] = []
    var isLive = false
    var isStarting = false
    var summarizedItemIds: [String] = []
  }

  struct Agent: Equatable {
    var toolCallId: String
    var taskId: String?

    func isRun(_ call: ToolCall) -> Bool {
      call.toolCallId == toolCallId || (call.kind == .agent && taskId != nil && call.subagentTaskId == taskId)
    }
  }

  static func collect(_ agent: Agent, from message: AssistantMessage, isActive: Bool, into thread: inout Thread) {
    let turn = message.turn
    let opened = SubagentMirror.spawningCall(agent.toolCallId, in: turn)
    let newRuns = registerRuns(agent, from: message, turn: turn, into: &thread)
    guard thread.spawn != nil else {
      if isActive, turn.isGenerating, let opened, !opened.isSettled, turn.isUnstartedSubagent(opened) {
        thread.isStarting = true
      }
      return
    }
    if turn.hasDeferredWorkedDetails, !turn.hasHydratedWorkedDetails, let itemId = turn.deferredDetailItemId {
      thread.summarizedItemIds.append(itemId)
    }
    appendSentMessages(agent, from: turn, into: &thread)
    appendRunPieces(newRuns, from: turn, into: &thread)
    markLiveRun(agent, from: turn, isActive: isActive, into: &thread)
  }

  private static func registerRuns(
    _ agent: Agent, from message: AssistantMessage, turn: AssistantTurn, into thread: inout Thread
  ) -> [ToolCall] {
    var newRuns: [ToolCall] = []
    for call in turn.allToolCalls
    where call.rawInput != nil && agent.isRun(call) && !thread.runIds.contains(call.toolCallId) {
      if thread.spawn == nil {
        registerSpawn(call, from: message, into: &thread)
      }
      thread.runIds.append(call.toolCallId)
      thread.latestRun = call
      newRuns.append(call)
    }
    return newRuns
  }

  private static func registerSpawn(_ call: ToolCall, from message: AssistantMessage, into thread: inout Thread) {
    thread.spawn = call
    thread.spawnMessageId = message.id
    thread.prompt = call.rawInput?["prompt"]?.stringValue
    thread.isMissingEarlierRuns = call.continuesSubagent
  }

  private static func appendSentMessages(_ agent: Agent, from turn: AssistantTurn, into thread: inout Thread) {
    let taskId = thread.spawn?.subagentTaskId
    for case let .tool(sent) in turn.entries
    where taskId != nil && sent.subagentTaskId == taskId && sent.kind != .agent && sent.toolCallId != agent.toolCallId {
      guard let text = sent.rawInput?["message"]?.stringValue, !text.isEmpty else { continue }
      thread.pieces.append(
        .followUp(
          key: sent.toolCallId, text: text,
          position: turn.entryPositions["tool:\(sent.toolCallId)"] ?? sent.statePosition))
    }
  }

  private static func appendRunPieces(_ newRuns: [ToolCall], from turn: AssistantTurn, into thread: inout Thread) {
    for runId in thread.runIds {
      if let run = newRuns.first(where: { $0.toolCallId == runId }),
        run.toolCallId != thread.spawn?.toolCallId || run.continuesSubagent
      {
        thread.pieces.append(
          .followUp(
            key: runId, text: run.rawInput?["message"]?.stringValue,
            position: turn.entryPositions["tool:\(runId)"] ?? run.statePosition))
      }
      var anchor: Int?
      for entry in turn.subagents[runId]?.entries ?? [] {
        anchor = turn.entryPositions[entry.id] ?? anchor
        thread.pieces.append(.work(entry, position: anchor, runId: runId, turn: turn))
      }
    }
  }

  private static func markLiveRun(_ agent: Agent, from turn: AssistantTurn, isActive: Bool, into thread: inout Thread) {
    if isActive, turn.isGenerating,
      turn.allToolCalls.contains(where: {
        !$0.isSettled && ($0.toolCallId == agent.toolCallId || thread.runIds.contains($0.toolCallId))
      })
    {
      thread.isLive = true
    }
  }
}
