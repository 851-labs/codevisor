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

  @Test("An agent whose finished turn reloads as the chat's latest summary is found again")
  func findsAgentInReloadedLatestTurn() async throws {
    let sessionId = UUID()
    let assistantId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    // A reload keeps the trailing finished turn active, summarized with its
    // tool calls deferred.
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [
        ServerTranscriptItem(
          id: assistantId.uuidString, sessionId: sessionId.uuidString, sequence: 0, role: .assistant,
          text: "The agent's haiku.", createdAt: "2026-08-31T00:00:00.000Z", updatedAt: "2026-08-31T00:00:02.000Z",
          isGenerating: false, hasDetails: true, turnId: "turn", startedAt: "2026-08-31T00:00:00.000Z",
          endedAt: "2026-08-31T00:00:02.000Z", stopReason: "end_turn", stopDetail: nil, planDocument: nil,
          attachments: nil, revision: 2)
      ],
      hasMore: false, eventCursor: 2)
    client.transcriptDetailsByItem[assistantId.uuidString] = ServerTranscriptItemDetails(
      itemId: assistantId.uuidString, revision: 2, eventCursor: 2,
      entries: [
        ServerTranscriptEntry(
          key: "tool:toolu_agent", position: 1, revision: 2,
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("toolu_agent"),
            "title": .string("Agent: Map the chat UI"), "kind": .string("other"), "status": .string("completed"),
            "rawInput": .object(["description": .string("Map the chat UI"), "prompt": .string("Map it.")]),
            "isSnapshot": .bool(true), "stateRevision": .number(2),
          ]))
      ])
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId), sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    await model.loadHistoryForInitialDisplay()
    let mirror = SubagentMirror(parent: SessionController.preview(model: model), toolCallId: "toolu_agent")

    mirror.start()
    await awaitObserved { mirror.availability != .loading }

    #expect(mirror.availability == .available)
    #expect(mirror.summary?.title == "Map the chat UI")
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

  @Test("An agent the model is still writing waits for its input instead of reading as unavailable")
  func agentStillBeingWritten() async throws {
    // Claude streams the call before its input: just an id and the tool name.
    let writing = AssistantTurn(
      entries: [.tool(ToolCall(toolCallId: "toolu_agent", title: "Agent", kind: .agent, status: .inProgress))],
      isGenerating: true, startedAt: start, subagents: ["toolu_agent": SubagentTranscript()])
    let (parent, parentModel) = parent(conversation(writing))
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")
    mirror.start()

    #expect(mirror.availability == .loading)

    parentModel.applyPreviewState(
      conversation: conversation(parentTurn(agentStatus: .inProgress, isGenerating: true, thread: [])),
      isSending: true)
    await awaitObserved { mirror.availability == .available }

    guard case let .user(prompt)? = mirror.controller.settledConversation.first else {
      Issue.record("expected the instructions as the user message")
      return
    }
    #expect(prompt.text == "Map how the transcript mounts rows.")
    #expect(try mirroredTurn(mirror).isGenerating)
  }

  @Test("A running agent with no instructions to show and no work yet reads as working")
  func promptlessAgentWorking() throws {
    // Codex encrypts its agents' instructions: the spawn names only the task.
    let spawn = ToolCall(
      toolCallId: "toolu_agent", title: "Agent: Map server storage", kind: .agent, status: .inProgress,
      rawInput: .object(["description": .string("Map server storage")]))
    let (parent, _) = parent(
      conversation(
        AssistantTurn(
          entries: [.tool(spawn)], isGenerating: true, startedAt: start,
          subagents: ["toolu_agent": SubagentTranscript()])))
    let mirror = SubagentMirror(parent: parent, toolCallId: "toolu_agent")

    mirror.update()

    #expect(mirror.availability == .available)
    #expect(mirror.controller.settledConversation.isEmpty)
    let turn = try mirroredTurn(mirror)
    #expect(turn.isGenerating)
    #expect(turn.isThinking)
    #expect(mirror.summary?.title == "Map server storage")
  }

  /// A Codex agent's chip: its task names it, its thread ties its runs.
  private func codexRun(_ id: String, status: ToolCallStatus, continues: Bool = false) -> ToolCall {
    var subagent: [String: JSONValue] = ["taskId": .string("thread-child")]
    if continues { subagent["continues"] = .bool(true) }
    return ToolCall(
      toolCallId: id, title: "Agent: Map server storage", kind: .agent, status: status,
      rawInput: .object(["description": .string("Map server storage")]),
      meta: .object(["codevisorSubagent": .object(subagent)]))
  }

  @Test(
    "An agent messaged in a later turn shows its whole history from either of its chips",
    arguments: ["call-spawn", "call-followup"])
  func laterRunsJoinTheHistory(opened: String) throws {
    let firstRun: [TranscriptEntry] = [.text(id: "t0", markdown: "Storage is SQLite.")]
    let secondRun: [TranscriptEntry] = [.text(id: "t1", markdown: "Paging uses a position cursor.")]
    let (parent, _) = parent([
      .user(UserMessage(text: "Map the server.")),
      .assistant(
        AssistantMessage(
          turn: AssistantTurn(
            entries: [.tool(codexRun("call-spawn", status: .completed))], startedAt: start,
            subagents: ["call-spawn": SubagentTranscript(entries: firstRun)]))),
      .user(UserMessage(text: "Ask it about paging.")),
      .assistant(
        AssistantMessage(
          turn: AssistantTurn(
            entries: [.tool(codexRun("call-followup", status: .inProgress, continues: true))],
            isGenerating: true, startedAt: start,
            subagents: ["call-followup": SubagentTranscript(entries: secondRun)]))),
    ])
    let mirror = SubagentMirror(parent: parent, toolCallId: opened)

    mirror.update()

    // Codex's messages to its agents are encrypted: the runs read as
    // consecutive responses, with no message between them.
    let settled = mirror.controller.settledConversation
    guard settled.count == 1, case let .assistant(first) = settled[0] else {
      Issue.record("expected the first run alone before the live one; got \(settled.count) items")
      return
    }
    #expect(first.turn.entries == firstRun)
    #expect(!first.turn.isGenerating)
    let answering = try mirroredTurn(mirror)
    #expect(answering.entries == secondRun)
    #expect(answering.isGenerating)
    #expect(mirror.summary?.isRunning == true)
    #expect(mirror.summary?.status == .inProgress)
  }

  @Test("A later run whose agent's spawn isn't loaded yet shows what it has")
  func laterRunWithoutItsSpawn() throws {
    let secondRun: [TranscriptEntry] = [.text(id: "t1", markdown: "Paging uses a position cursor.")]
    let (parent, _) = parent(
      conversation(
        AssistantTurn(
          entries: [.tool(codexRun("call-followup", status: .inProgress, continues: true))],
          isGenerating: true, startedAt: start,
          subagents: ["call-followup": SubagentTranscript(entries: secondRun)])))
    let mirror = SubagentMirror(parent: parent, toolCallId: "call-followup")

    mirror.update()

    #expect(mirror.availability == .available)
    #expect(mirror.controller.settledConversation.isEmpty)
    #expect(try mirroredTurn(mirror).entries == secondRun)
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
