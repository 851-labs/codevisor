import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Background task snapshots drive the waiting indicator")
  func backgroundTaskWaiting() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    await model.send("run tests in the background")
    await settleUntil { !model.isSending }
    #expect(model.isSending == false)
    #expect(model.isWaitingOnBackgroundTasks == false)

    client.emit(
      ServerEventEnvelope(
        id: 3,
        serverId: "local",
        kind: "session.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-06-30T00:00:02.000Z",
        payload: .object([
          "backgroundTasks": .array([
            .object([
              "id": .string("bg-1"),
              "description": .string("Explore the test suite"),
              "status": .string("running"),
              "taskType": .string("subagent"),
              "toolUseId": .string("tool-0"),
            ])
          ])
        ])
      ))
    await settleUntil { !model.backgroundTasks.isEmpty }
    #expect(
      model.backgroundTasks == [
        BackgroundTaskInfo(
          id: "bg-1",
          description: "Explore the test suite",
          status: "running",
          taskType: "subagent",
          toolUseId: "tool-0"
        )
      ])
    #expect(model.isWaitingOnBackgroundTasks)

    client.emit(
      ServerEventEnvelope(
        id: 4,
        serverId: "local",
        kind: "session.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-06-30T00:00:02.250Z",
        payload: .object([
          "backgroundTasks": .array([
            .object([
              "id": .string("bg-1b"),
              "description": .string("bun run check — failures only"),
              "status": .string("running"),
              "taskType": .string("local_bash"),
              "toolUseId": .string("tool-0b"),
            ])
          ])
        ])
      ))
    await settleUntil { model.backgroundTasks.first?.id == "bg-1b" }
    #expect(model.waitingBackgroundTasks.isEmpty)
    #expect(model.isWaitingOnBackgroundTasks == false)

    client.emit(
      ServerEventEnvelope(
        id: 6,
        serverId: "local",
        kind: "session.updated",
        subjectId: sessionId.uuidString,
        createdAt: "2026-06-30T00:00:03.000Z",
        payload: .object(["backgroundTasks": .array([])])
      ))
    await settleUntil { model.backgroundTasks.isEmpty }
    #expect(model.isWaitingOnBackgroundTasks == false)
  }

  @Test("A late settle for a subagent child merges into the finished turn")
  func lateChildSettleMerges() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    await model.send("spawn an agent")
    client.emit(
      ServerEventEnvelope(
        id: 1, serverId: "local", kind: "session.output",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
        payload: .object([
          "sessionUpdate": .string("tool_call"),
          "toolCallId": .string("task-1"),
          "title": .string("Agent: explore"),
          "kind": .string("agent"),
          "status": .string("in_progress"),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 2, serverId: "local", kind: "session.output",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:01.000Z",
        payload: .object([
          "sessionUpdate": .string("tool_call"),
          "toolCallId": .string("sub-1"),
          "title": .string("Read"),
          "status": .string("in_progress"),
          "parentToolCallId": .string("task-1"),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 3, serverId: "local", kind: "session.updated",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:02.000Z",
        payload: .object(["stopReason": .string("end_turn")])
      ))
    await settleUntil { model.isSending == false }
    let countAfterFinish = model.conversation.count

    client.emit(
      ServerEventEnvelope(
        id: 4, serverId: "local", kind: "session.output",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:03.000Z",
        payload: .object([
          "sessionUpdate": .string("tool_call_update"),
          "toolCallId": .string("sub-1"),
          "status": .string("failed"),
        ])
      ))
    await settleUntil {
      if case let .assistant(message) = model.conversation.last,
        case let .tool(child)? = message.turn.subagents["task-1"]?.entries.first
      {
        return child.status == .failed
      }
      return false
    }
    #expect(model.conversation.count == countAfterFinish)
    guard case let .assistant(message) = model.conversation.last else {
      Issue.record("expected assistant")
      return
    }
    #expect(message.turn.isGenerating == false)
    guard case let .tool(child)? = message.turn.subagents["task-1"]?.entries.first else {
      Issue.record("expected nested child")
      return
    }
    #expect(child.status == .failed)
  }

  @Test("Background subagent output after turn end merges into the owning bubble")
  func crossTurnSubagentRouting() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString
    )

    await model.send("spawn a background agent")
    client.emit(
      ServerEventEnvelope(
        id: 1, serverId: "local", kind: "session.output",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:00.000Z",
        payload: .object([
          "sessionUpdate": .string("tool_call"),
          "toolCallId": .string("task-1"),
          "title": .string("Agent: explore"),
          "kind": .string("agent"),
          "status": .string("completed"),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 2, serverId: "local", kind: "session.updated",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:01.000Z",
        payload: .object(["stopReason": .string("end_turn")])
      ))
    await settleUntil { model.isSending == false }
    let bubblesAfterFinish = model.conversation.count

    client.emit(
      ServerEventEnvelope(
        id: 3, serverId: "local", kind: "session.output",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:02.000Z",
        payload: .object([
          "sessionUpdate": .string("agent_message_chunk"),
          "content": .object(["type": .string("text"), "text": .string("Here is my report.")]),
          "messageId": .string("msg-late"),
          "parentToolCallId": .string("task-1"),
        ])
      ))
    client.emit(
      ServerEventEnvelope(
        id: 4, serverId: "local", kind: "session.output",
        subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:03.000Z",
        payload: .object([
          "sessionUpdate": .string("tool_call_update"),
          "toolCallId": .string("sub-late"),
          "title": .string("Read files"),
          "status": .string("in_progress"),
          "parentToolCallId": .string("task-1"),
        ])
      ))
    await settleUntil {
      if case let .assistant(message) = model.conversation.last {
        return message.turn.subagents["task-1"]?.entries.count == 2
      }
      return false
    }

    #expect(model.conversation.count == bubblesAfterFinish)
    #expect(model.isSending == false)
    guard case let .assistant(message) = model.conversation.last else {
      Issue.record("expected assistant")
      return
    }
    #expect(message.turn.isGenerating == false)
    #expect(
      message.turn.subagents["task-1"]?.entries == [
        .text(id: "acp:msg-late", markdown: "Here is my report."),
        .tool(
          ToolCall(
            toolCallId: "sub-late",
            title: "Read files",
            status: .inProgress,
            parentToolCallId: "task-1"
          )),
      ])
  }

  @Test("A background agent still running after reopening the chat is named by its spawn, not its placeholder")
  func waitingAgentNamedAfterReopen() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let itemId = UUID()
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [transcriptStateItem(id: itemId, sessionId: sessionId, hasDetails: true)], hasMore: false,
      eventCursor: 5,
      backgroundTasks: [
        BackgroundTaskInfo(
          id: "bg-1", description: "Reading Measurement.swift", status: "running", taskType: "subagent",
          toolUseId: "task-1")
      ])
    client.transcriptDetailsByItem[itemId.uuidString] = ServerTranscriptItemDetails(
      itemId: itemId.uuidString, revision: 1, eventCursor: 5,
      entries: [
        .init(
          key: "tool:task-1", position: 1, revision: 1,
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("task-1"),
            "title": .string("Agent: Map the chat UI"), "kind": .string("agent"), "status": .string("in_progress"),
            "rawInput": .object(["description": .string("Map the chat UI")]),
          ]))
      ])

    await model(client, sessionId: sessionId) { model in
      await model.loadHistoryForInitialDisplay()
      client.emit(
        ServerEventEnvelope(
          id: 6, serverId: "local", kind: "session.output",
          subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:06.000Z",
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("sub-1"), "title": .string("Read"),
            "status": .string("in_progress"), "parentToolCallId": .string("task-1"),
            "chatItemId": .string(itemId.uuidString),
          ])))
      await settleUntil { model.waitingSubagentCalls.first?.rawInput != nil }

      #expect(model.waitingSubagentCalls.map(\.agentName) == ["Map the chat UI"])
      guard case let .assistant(message) = model.conversation.last else {
        Issue.record("expected assistant")
        return
      }
      #expect(message.turn.subagents["task-1"]?.entries.map(\.id) == ["tool:sub-1"])
    }
  }

  @Test("History replay rebuilds nested subagent transcripts and the last background snapshot wins")
  func historyReplaysNestingAndBackgroundTasks() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let itemId = UUID()
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [
        transcriptStateItem(id: itemId, sessionId: sessionId, hasDetails: true)
      ], hasMore: false, eventCursor: 5,
      backgroundTasks: [
        BackgroundTaskInfo(id: "bg-9", description: "Long build", status: "running", taskType: "subagent")
      ])
    client.transcriptDetailsByItem[itemId.uuidString] = ServerTranscriptItemDetails(
      itemId: itemId.uuidString, revision: 1, eventCursor: 5,
      entries: [
        .init(
          key: "tool:task-1", position: 1, revision: 1,
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("task-1"), "title": .string("Agent: explore"),
            "kind": .string("agent"), "status": .string("completed"),
          ])),
        .init(
          key: "message:task-1:msg-sub", position: 2, revision: 2,
          payload: .object([
            "sessionUpdate": .string("agent_message_patch"), "messageId": .string("msg-sub"),
            "text": .string("child prose"), "offset": .number(0), "totalLength": .number(11),
            "generation": .number(0), "stateRevision": .number(2), "parentToolCallId": .string("task-1"),
          ])),
      ])

    await model(client, sessionId: sessionId) { model in
      await model.loadHistoryForInitialDisplay()
      #expect(await model.transcriptDetails.load(itemId: itemId.uuidString))
      guard case let .assistant(message) = model.conversation.last else {
        Issue.record("expected assistant")
        return
      }
      #expect(message.turn.entries.map(\.id) == ["tool:task-1"])
      #expect(message.turn.subagents["task-1"]?.entries == [.text(id: "acp:msg-sub", markdown: "child prose")])
      #expect(model.isSending == false)
      #expect(model.backgroundTasks.map(\.id) == ["bg-9"])
      #expect(model.isWaitingOnBackgroundTasks)
    }
  }
}
