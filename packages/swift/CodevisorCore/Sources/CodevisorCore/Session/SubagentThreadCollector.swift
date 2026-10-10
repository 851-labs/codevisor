import ACPKit
import Foundation
import TranscriptKit

/// Collects parent transcript pieces on the same actor as their mirror.
@MainActor
enum SubagentThreadCollector {
  /// One piece of the agent's conversation, as read from the parent.
  enum Piece: Equatable {
    /// A message sent to the agent after its spawn (Claude's `SendMessage`),
    /// or a later run starting without one to show (Codex encrypts them).
    case followUp(key: String, text: String?, position: Int?)
    /// One entry of the agent's own thread, in the parent item it streamed
    /// into under one of its runs' calls.
    case work(TranscriptEntry, position: Int?, runId: String, turn: AssistantTurn)

    var position: Int? {
      switch self {
      case let .followUp(_, _, position), let .work(_, position, _, _): position
      }
    }
  }

  /// The agent's conversation gathered from the parent's items.
  struct Thread: Equatable {
    var spawn: ToolCall?
    var spawnMessageId: UUID?
    var prompt: String?
    /// The agent's runs found so far, in order: the spawn, then later runs.
    var runIds: [String] = []
    var latestRun: ToolCall?
    /// The earliest run found continues an agent spawned in history not yet
    /// loaded: keep searching for the rest of its history.
    var isMissingEarlierRuns = false
    var pieces: [Piece] = []
    /// Its spawning (or continuing) call is open in a generating item.
    var isLive = false
    /// The model is still writing its spawning call: the agent appears once
    /// the call's input arrives, so there's nothing to search for.
    var isStarting = false
    /// Parent items after the spawn still in summary form: their details may
    /// hold messages sent to the agent, or its later work.
    var summarizedItemIds: [String] = []
  }

  /// Which calls are the agent's runs. Opening any of them shows them all:
  /// the call itself, and every agent call sharing its task id (a Codex
  /// agent messaged in a later turn gets a chip there for its new run).
  struct Agent: Equatable {
    var toolCallId: String
    var taskId: String?

    func isRun(_ call: ToolCall) -> Bool {
      call.toolCallId == toolCallId || (call.kind == .agent && taskId != nil && call.subagentTaskId == taskId)
    }
  }

  /// Adds one parent item's part of the agent's conversation: its spawn and
  /// later runs, messages sent to it, and the entries it streamed there.
  static func collect(_ agent: Agent, from message: AssistantMessage, isActive: Bool, into thread: inout Thread) {
    let turn = message.turn
    let opened = SubagentMirror.spawningCall(agent.toolCallId, in: turn)
    // A run's call carries its input; an item a run only continues in holds
    // a bare placeholder call for its thread.
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
    // Messages sent to the agent name the same task as its spawn.
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
      // A later run starts with the message that started it (Codex's are
      // encrypted: then just a new run); the first found does too when it
      // continues an agent spawned earlier.
      if let run = newRuns.first(where: { $0.toolCallId == runId }),
        run.toolCallId != thread.spawn?.toolCallId || run.continuesSubagent
      {
        thread.pieces.append(
          .followUp(
            key: runId, text: run.rawInput?["message"]?.stringValue,
            position: turn.entryPositions["tool:\(runId)"] ?? run.statePosition))
      }
      // An entry without its own position stays behind the one before it,
      // as the parent's transcript orders entries.
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
