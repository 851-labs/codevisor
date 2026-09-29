import ACPKit
import CodevisorTestSupport
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorCore

/// A subagent's thread, read from its parent chat, presented as a
/// conversation of its own.
@MainActor
@Suite("Subagent mirror", .timeLimit(.minutes(1)))
struct SubagentMirrorTests {
  private let start = Date(timeIntervalSince1970: 1_000)
  private let seenDone = Date(timeIntervalSince1970: 1_042)

  private func agentCall(status: ToolCallStatus) -> ToolCall {
    ToolCall(
      toolCallId: "toolu_agent", title: "Agent: Map the chat UI", kind: .agent, status: status,
      rawInput: .object([
        "description": .string("Map the chat UI"),
        "subagent_type": .string("Explore"),
        "prompt": .string("Map how the transcript mounts rows."),
      ]),
      meta: .object(["codevisorSubagent": .object(["taskId": .string("agent-1")])]))
  }

  private func parentTurn(
    agentStatus: ToolCallStatus, isGenerating: Bool, thread: [TranscriptEntry]
  ) -> AssistantTurn {
    AssistantTurn(
      entries: [.tool(agentCall(status: agentStatus))],
      isGenerating: isGenerating,
      startedAt: start,
      endedAt: isGenerating ? nil : start.addingTimeInterval(60),
      subagents: ["toolu_agent": SubagentTranscript(entries: thread)]
    )
  }

  private let thread: [TranscriptEntry] = [
    .text(id: "t0", markdown: "Starting with the scroll view."),
    .tool(ToolCall(toolCallId: "read-1", title: "Read Scroll.swift", kind: .read, status: .completed)),
    .text(id: "t1", markdown: "Rows are virtualized."),
  ]

  private func parent(_ conversation: [ConversationItem]) -> (SessionController, SessionModel) {
    let model = SessionModel.preview(conversation: conversation)
    return (SessionController.preview(model: model), model)
  }

  private func conversation(_ turn: AssistantTurn) -> [ConversationItem] {
    [.user(UserMessage(text: "Why is it slow?")), .assistant(AssistantMessage(turn: turn))]
  }

  private func mirroredTurn(_ mirror: SubagentMirror) throws -> AssistantTurn {
    try #require(mirroredTurnIfPresent(mirror))
  }

  private func mirroredTurnIfPresent(_ mirror: SubagentMirror) -> AssistantTurn? {
    guard case let .assistant(message)? = mirror.controller.activeItem else { return nil }
    return message.turn
  }

  @Test("A finished agent reads as its own chat: instructions, then its work, then its answer")
  func finishedAgent() throws {
    let (parent, _) = parent(
      conversation(parentTurn(agentStatus: .completed, isGenerating: false, thread: thread)))
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")

    mirror.update()

    #expect(mirror.availability == .available)
    guard case let .user(prompt)? = mirror.controller.settledConversation.first else {
      Issue.record("expected the instructions as the user message")
      return
    }
    #expect(prompt.text == "Map how the transcript mounts rows.")
    let turn = try mirroredTurn(mirror)
    #expect(turn.entries == thread)
    #expect(!turn.isGenerating)
    #expect(turn.finalTextIndex == 2)
    #expect(turn.textPhases["t0"] == .commentary)
    #expect(
      mirror.summary == .init(title: "Map the chat UI", agentType: "Explore", isRunning: false, status: .completed))
  }

  @Test("While the agent runs, its prose is progress rather than an answer, and new work streams in")
  func runningAgentStreams() async throws {
    let (parent, parentModel) = parent(
      conversation(parentTurn(agentStatus: .inProgress, isGenerating: true, thread: Array(thread.prefix(2)))))
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")
    mirror.start()

    var turn = try mirroredTurn(mirror)
    #expect(turn.isGenerating)
    #expect(turn.finalTextIndex == nil)
    #expect(mirror.summary?.isRunning == true)

    parentModel.applyPreviewState(
      conversation: conversation(parentTurn(agentStatus: .inProgress, isGenerating: true, thread: thread)),
      isSending: true)
    await awaitObserved { mirroredTurnIfPresent(mirror)?.entries == thread }

    turn = try mirroredTurn(mirror)
    #expect(turn.finalTextIndex == nil)
  }

  @Test("An agent that finished inside a still-running turn is timed to when it was seen done")
  func finishedInsideRunningTurn() throws {
    let (parent, _) = parent(
      conversation(parentTurn(agentStatus: .completed, isGenerating: true, thread: thread)))
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent", now: { [seenDone] in seenDone })

    mirror.update()

    let turn = try mirroredTurn(mirror)
    #expect(!turn.isGenerating)
    #expect(turn.startedAt == start)
    #expect(turn.endedAt == seenDone)
    #expect(turn.finalTextIndex == 2)
  }

  @Test("An agent on screen keeps showing while its parent reloads history")
  func keepsShowingThroughParentReload() throws {
    let (parent, _) = parent(
      conversation(parentTurn(agentStatus: .completed, isGenerating: false, thread: thread)))
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")
    mirror.update()
    #expect(mirror.availability == .available)

    parent.isLoadingInitialHistory = true
    mirror.update()

    #expect(mirror.availability == .available)
    #expect(try mirroredTurn(mirror).entries == thread)
  }

  @Test("A message sent to the agent later continues its conversation, answered live in a later item")
  func followUpContinuesTheConversation() throws {
    let followUp = ToolCall(
      toolCallId: "toolu_follow_up", title: "Messaged agent: Map the chat UI", kind: .other, status: .completed,
      rawInput: .object(["to": .string("agent-1"), "message": .string("Which file is the hot loop in?")]),
      meta: .object(["codevisorSubagent": .object(["taskId": .string("agent-1")])]))
    let answer: [TranscriptEntry] = [.text(id: "t0", markdown: "The hot loop is in Measurement.swift.")]
    let (parent, _) = parent([
      .user(UserMessage(text: "Why is it slow?")),
      .assistant(AssistantMessage(turn: parentTurn(agentStatus: .completed, isGenerating: false, thread: thread))),
      .user(UserMessage(text: "Ask it where the hot loop is.")),
      .assistant(AssistantMessage(turn: AssistantTurn(entries: [.tool(followUp)], startedAt: start))),
      // The resumed agent streams under its spawning call's id, in an item
      // holding only a placeholder for that call.
      .assistant(
        AssistantMessage(
          turn: AssistantTurn(
            entries: [.tool(ToolCall(toolCallId: "toolu_agent", title: "Subagent", kind: .agent, status: .inProgress))],
            isGenerating: true, startedAt: start,
            subagents: ["toolu_agent": SubagentTranscript(entries: answer)]))),
    ])
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")

    mirror.update()

    let settled = mirror.controller.settledConversation
    #expect(settled.count == 3)
    guard case let .user(prompt) = settled[0], case let .assistant(firstRun) = settled[1],
      case let .user(message) = settled[2]
    else {
      Issue.record("expected instructions, first run, then the follow-up")
      return
    }
    #expect(prompt.text == "Map how the transcript mounts rows.")
    #expect(firstRun.turn.entries == thread)
    #expect(!firstRun.turn.isGenerating)
    #expect(message.text == "Which file is the hot loop in?")
    let answering = try mirroredTurn(mirror)
    #expect(answering.entries == answer)
    #expect(answering.isGenerating)
    #expect(mirror.summary?.isRunning == true)
    #expect(mirror.summary?.title == "Map the chat UI")
  }

  @Test("A follow-up's answer that streams back into the agent's first item still reads after the follow-up")
  func followUpAnswerInTheSpawningItem() throws {
    let followUp = ToolCall(
      toolCallId: "toolu_follow_up", title: "Messaged agent: Map the chat UI", kind: .other, status: .completed,
      rawInput: .object(["message": .string("Which file is the hot loop in?")]),
      meta: .object(["codevisorSubagent": .object(["taskId": .string("agent-1")])]))
    let answer = TranscriptEntry.text(id: "t2", markdown: "The hot loop is in Measurement.swift.")
    var spawning = parentTurn(agentStatus: .completed, isGenerating: false, thread: thread + [answer])
    spawning.entryPositions = ["tool:toolu_agent": 1, "text:t0": 10, "tool:read-1": 12, "text:t1": 20, "text:t2": 60]
    var messaging = AssistantTurn(entries: [.tool(followUp)], startedAt: start)
    messaging.entryPositions = ["tool:toolu_follow_up": 45]
    let (parent, _) = parent([
      .user(UserMessage(text: "Why is it slow?")),
      .assistant(AssistantMessage(turn: spawning)),
      .user(UserMessage(text: "Ask it where the hot loop is.")),
      .assistant(AssistantMessage(turn: messaging)),
    ])
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")

    mirror.update()

    let settled = mirror.controller.settledConversation
    guard settled.count == 3, case let .assistant(firstRun) = settled[1], case let .user(message) = settled[2]
    else {
      Issue.record("expected instructions, first run, then the follow-up; got \(settled.count) items")
      return
    }
    #expect(firstRun.turn.entries == thread)
    #expect(message.text == "Which file is the hot loop in?")
    #expect(try mirroredTurn(mirror).entries == [answer])
  }

  @Test("An agent answering a follow-up shows as running under the call that spawned it")
  func followUpRunIsTheSpawnsRun() {
    let followUp = ToolCall(
      toolCallId: "toolu_follow_up", title: "SendMessage", kind: .other, status: .inProgress,
      meta: .object(["codevisorSubagent": .object(["taskId": .string("agent-1")])]))
    let (parent, parentModel) = parent([
      .assistant(AssistantMessage(turn: parentTurn(agentStatus: .completed, isGenerating: false, thread: thread))),
      .assistant(AssistantMessage(turn: AssistantTurn(entries: [.tool(followUp)], isGenerating: true))),
    ])

    parentModel.backgroundTasks = [
      BackgroundTaskInfo(
        id: "agent-1", description: "Map the chat UI", status: "running", taskType: "subagent",
        toolUseId: "toolu_follow_up")
    ]

    #expect(parent.runningSubagentToolCallIds == ["toolu_agent"])
  }

  @Test("An agent missing from the parent's complete history is unavailable")
  func missingAgent() {
    let (parent, _) = parent(
      conversation(AssistantTurn(entries: [.text(id: "t0", markdown: "No agents here.")], startedAt: start)))
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")

    mirror.update()

    #expect(mirror.availability == .unavailable)
    #expect(mirror.controller.activeItem == nil)
  }
}
