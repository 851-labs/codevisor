import Foundation
import Testing
import ACPKit
@testable import TranscriptKit

extension TranscriptReducerTests {
  // MARK: - Subagent routing

  @Test("Parented chunks land in the subagent bucket without touching main state")
  func subagentChunksRouted() {
    let turn = reduce([
      .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: explore", kind: .agent, status: .inProgress)),
      .agentThoughtChunk(.text("hmm"), messageId: nil, parentToolCallId: "task-1"),
      .agentMessageChunk(.text("child "), messageId: "msg-sub", parentToolCallId: "task-1"),
      .agentMessageChunk(.text("text"), messageId: "msg-sub", parentToolCallId: "task-1"),
    ])
    #expect(turn.entries.map(\.id) == ["tool:task-1"])
    let bucket = turn.subagents["task-1"]
    #expect(bucket?.entries == [.text(id: "acp:msg-sub", markdown: "child text")])
    // The thought chunk flipped the bucket's thinking, then text cleared it.
    #expect(bucket?.isThinking == false)
    // Main thinking state was never flipped false by parented text (only
    // the parent tool_call itself cleared it).
    #expect(turn.isThinking == false)
  }

  @Test("Parented thought chunks flip only the bucket's thinking state")
  func subagentThinkingIsolated() {
    var turn = AssistantTurn(isGenerating: true, isThinking: true)
    TranscriptReducer.apply(
      .agentThoughtChunk(.text("child hmm"), messageId: nil, parentToolCallId: "task-1"), to: &turn)
    #expect(turn.isThinking == true)
    #expect(turn.subagents["task-1"]?.isThinking == true)
    #expect(turn.subagents["task-1"]?.entries.isEmpty == true)
  }

  @Test("An agent tool call eagerly creates its empty bucket")
  func eagerBucket() {
    let turn = reduce([
      .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: explore", kind: .agent, status: .inProgress))
    ])
    #expect(turn.subagents["task-1"] != nil)
    #expect(turn.subagents["task-1"]?.entries.isEmpty == true)
  }

  @Test("Concurrent subagents stream into independent buckets")
  func concurrentBuckets() {
    let turn = reduce([
      .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: a", kind: .agent)),
      .toolCall(ToolCall(toolCallId: "task-2", title: "Agent: b", kind: .agent)),
      .agentMessageChunk(.text("one "), messageId: nil, parentToolCallId: "task-1"),
      .agentMessageChunk(.text("two "), messageId: nil, parentToolCallId: "task-2"),
      .agentMessageChunk(.text("more"), messageId: nil, parentToolCallId: "task-1"),
      .agentMessageChunk(.text("main text")),
    ])
    #expect(turn.subagents["task-1"]?.entries == [.text(id: "t0", markdown: "one more")])
    #expect(turn.subagents["task-2"]?.entries == [.text(id: "t0", markdown: "two ")])
    #expect(turn.entries.map(\.id) == ["tool:task-1", "tool:task-2", "text:t0"])
  }

  @Test("Parented tool calls nest; unparented updates settle them by id lookup")
  func childToolSettleByLookup() {
    let turn = reduce([
      .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: explore", kind: .agent)),
      .toolCall(
        ToolCall(
          toolCallId: "sub-read", title: "Read", kind: .read, status: .inProgress, parentToolCallId: "task-1")
      ),
      // Settle updates (tool results) carry no parent attribution.
      .toolCallUpdate(ToolCallUpdate(toolCallId: "sub-read", status: .completed)),
    ])
    #expect(turn.entries.map(\.id) == ["tool:task-1"])
    guard case let .tool(child)? = turn.subagents["task-1"]?.entries.first else {
      Issue.record("expected nested tool")
      return
    }
    #expect(child.toolCallId == "sub-read")
    #expect(child.status == .completed)
  }

  @Test("An unseen update with parent attribution creates the bucket")
  func unseenParentedUpdate() {
    let turn = reduce([
      .toolCallUpdate(ToolCallUpdate(toolCallId: "sub-x", status: .inProgress, parentToolCallId: "task-9"))
    ])
    #expect(turn.entries.isEmpty)
    guard case let .tool(child)? = turn.subagents["task-9"]?.entries.first else {
      Issue.record("expected nested tool")
      return
    }
    #expect(child.toolCallId == "sub-x")
  }

  @Test("Settling the parent Task cascades to its children, recursively")
  func cascadeSettle() {
    var turn = reduce([
      .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: outer", kind: .agent, status: .inProgress)),
      .toolCall(
        ToolCall(
          toolCallId: "task-2", title: "Agent: inner", kind: .agent, status: .inProgress,
          parentToolCallId: "task-1")),
      .toolCall(
        ToolCall(
          toolCallId: "sub-run", title: "Run", kind: .execute, status: .inProgress, parentToolCallId: "task-2"
        )),
    ])
    TranscriptReducer.apply(.agentThoughtChunk(.text("x"), messageId: nil, parentToolCallId: "task-2"), to: &turn)
    TranscriptReducer.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "task-1", status: .completed)), to: &turn)

    guard case let .tool(inner)? = turn.subagents["task-1"]?.entries.first,
      case let .tool(grandchild)? = turn.subagents["task-2"]?.entries.first
    else {
      Issue.record("expected nested tools")
      return
    }
    #expect(inner.status == .completed)
    #expect(grandchild.status == .completed)
    #expect(turn.subagents["task-2"]?.isThinking == false)
  }

  @Test("settleToolCalls recurses into subagent buckets and clears their thinking")
  func settleRecursesBuckets() {
    var turn = reduce([
      .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: explore", kind: .agent, status: .inProgress)),
      .toolCall(
        ToolCall(
          toolCallId: "sub-read", title: "Read", kind: .read, status: .inProgress, parentToolCallId: "task-1")
      ),
    ])
    TranscriptReducer.apply(.agentThoughtChunk(.text("x"), messageId: nil, parentToolCallId: "task-1"), to: &turn)
    TranscriptReducer.settleToolCalls(&turn, outcome: .cancelled)
    #expect(turn.toolCalls.first?.status == .cancelled)
    guard case let .tool(child)? = turn.subagents["task-1"]?.entries.first else {
      Issue.record("expected nested tool")
      return
    }
    #expect(child.status == .cancelled)
    #expect(turn.subagents["task-1"]?.isThinking == false)
  }

  @Test("allToolCalls spans main entries and every bucket")
  func allToolCallsSpansBuckets() {
    let turn = reduce([
      .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: explore", kind: .agent)),
      .toolCall(ToolCall(toolCallId: "sub-read", title: "Read", kind: .read, parentToolCallId: "task-1")),
      .toolCall(ToolCall(toolCallId: "main-run", title: "Run", kind: .execute)),
    ])
    #expect(Set(turn.allToolCalls.map(\.toolCallId)) == ["task-1", "sub-read", "main-run"])
  }

  @Test("settleToolCalls maps the outcome onto non-terminal calls only")
  func settleOutcomes() {
    var turn = reduce([
      .toolCall(ToolCall(toolCallId: "done", title: "Read", status: .completed)),
      .toolCall(ToolCall(toolCallId: "running", title: "Edit", status: .inProgress)),
      .toolCall(ToolCall(toolCallId: "pending", title: "Run", status: .pending)),
      .toolCall(ToolCall(toolCallId: "statusless", title: "Fetch")),
      .toolCall(ToolCall(toolCallId: "broken", title: "Bash", status: .failed)),
    ])
    TranscriptReducer.settleToolCalls(&turn, outcome: .cancelled)
    let statuses = turn.toolCalls.map(\.status)
    #expect(statuses == [.completed, .cancelled, .cancelled, .cancelled, .failed])

    var completedTurn = reduce([
      .toolCall(ToolCall(toolCallId: "running", title: "Edit", status: .inProgress))
    ])
    TranscriptReducer.settleToolCalls(&completedTurn, outcome: .completed)
    #expect(completedTurn.toolCalls.first?.status == .completed)

    var failedTurn = reduce([
      .toolCall(ToolCall(toolCallId: "running", title: "Edit", status: .inProgress))
    ])
    TranscriptReducer.settleToolCalls(&failedTurn, outcome: .failed)
    #expect(failedTurn.toolCalls.first?.status == .failed)
  }
}
