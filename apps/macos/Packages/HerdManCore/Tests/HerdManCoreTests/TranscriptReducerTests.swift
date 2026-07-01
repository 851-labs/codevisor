import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@Suite("TranscriptReducer")
struct TranscriptReducerTests {
    private func reduce(_ updates: [SessionUpdate]) -> AssistantTurn {
        var turn = AssistantTurn(isGenerating: true, isThinking: true)
        for update in updates { TranscriptReducer.apply(update, to: &turn) }
        return turn
    }

    @Test("Consecutive text chunks extend a single span")
    func mergesText() {
        let turn = reduce([
            .agentMessageChunk(.text("Hello ")),
            .agentMessageChunk(.text("world"))
        ])
        #expect(turn.entries.count == 1)
        #expect(turn.entries.first == .text(id: "t0", markdown: "Hello world"))
        #expect(turn.isThinking == false)
    }

    @Test("Preserves interleaved order: text → tool → tool → text → tool → text")
    func interleavedOrder() {
        let turn = reduce([
            .agentMessageChunk(.text("first")),
            .toolCall(ToolCall(toolCallId: "a", title: "Read")),
            .toolCall(ToolCall(toolCallId: "b", title: "Search")),
            .agentMessageChunk(.text("middle")),
            .toolCall(ToolCall(toolCallId: "c", title: "Run")),
            .agentMessageChunk(.text("final"))
        ])
        #expect(turn.entries.map(\.id) == [
            "text:t0", "tool:a", "tool:b", "text:t1", "tool:c", "text:t2"
        ])
    }

    @Test("Text after a tool call starts a new span")
    func newSpanAfterTool() {
        let turn = reduce([
            .agentMessageChunk(.text("before")),
            .toolCall(ToolCall(toolCallId: "a", title: "T")),
            .agentMessageChunk(.text("after"))
        ])
        #expect(turn.entries.count == 3)
        #expect(turn.entries[2] == .text(id: "t1", markdown: "after"))
    }

    @Test("ACP message ids merge chunks across interleaved tool calls")
    func messageIdMergesAcrossTools() {
        let turn = reduce([
            .agentMessageChunk(.text("I'll check."), messageId: "msg-prelude"),
            .toolCall(ToolCall(toolCallId: "a", title: "Read README", kind: .read, status: .completed)),
            .agentMessageChunk(.text("Barnsong is "), messageId: "msg-final"),
            .toolCall(ToolCall(toolCallId: "b", title: "Read package", kind: .read, status: .completed)),
            .agentMessageChunk(.text("a game."), messageId: "msg-final"),
            .toolCall(ToolCall(toolCallId: "c", title: "Run tests", kind: .execute, status: .completed))
        ])

        #expect(turn.entries.map(\.id) == [
            "text:acp:msg-prelude",
            "tool:a",
            "text:acp:msg-final",
            "tool:b",
            "tool:c"
        ])
        #expect(turn.finalText == .text(id: "acp:msg-final", markdown: "Barnsong is a game."))
        #expect(turn.workedEntries.map(\.id) == [
            "text:acp:msg-prelude",
            "tool:a",
            "tool:b",
            "tool:c"
        ])
    }

    @Test("Tool call updates merge into the existing entry in place")
    func toolUpdateMerges() {
        let turn = reduce([
            .toolCall(ToolCall(toolCallId: "a", title: "Read", status: .pending)),
            .agentMessageChunk(.text("note")),
            .toolCallUpdate(ToolCallUpdate(toolCallId: "a", status: .completed, content: [.content(.text("done"))]))
        ])
        // The tool entry stays at index 0 (order preserved), now completed.
        guard case let .tool(call) = turn.entries[0] else { Issue.record("expected tool"); return }
        #expect(call.status == .completed)
        #expect(call.title == "Read")
        #expect(call.content?.count == 1)
        #expect(turn.entries.count == 2)
    }

    @Test("A tool update for an unseen id appends a new tool entry")
    func toolUpdateUnseen() {
        let turn = reduce([
            .toolCallUpdate(ToolCallUpdate(toolCallId: "x", status: .inProgress))
        ])
        #expect(turn.entries.count == 1)
        guard case let .tool(call) = turn.entries[0] else { Issue.record("expected tool"); return }
        #expect(call.toolCallId == "x")
    }

    @Test("Thought chunks toggle the thinking indicator without adding entries")
    func thinking() {
        var turn = AssistantTurn(isGenerating: true)
        TranscriptReducer.apply(.agentThoughtChunk(.text("hmm")), to: &turn)
        #expect(turn.isThinking)
        #expect(turn.entries.isEmpty)
        TranscriptReducer.apply(.agentMessageChunk(.text("answer")), to: &turn)
        #expect(turn.isThinking == false)
        #expect(turn.entries.count == 1)
    }

    @Test("Empty text chunks are ignored")
    func emptyText() {
        let turn = reduce([.agentMessageChunk(.text(""))])
        #expect(turn.entries.isEmpty)
    }

    @Test("Plan updates are captured; commands and mode updates are ignored")
    func planAndIgnored() {
        var turn = AssistantTurn()
        TranscriptReducer.apply(.plan(Plan(entries: [PlanEntry(content: "step", priority: .high, status: .pending)])), to: &turn)
        TranscriptReducer.apply(.availableCommandsUpdate([AvailableCommand(name: "x", description: "y")]), to: &turn)
        TranscriptReducer.apply(.currentModeUpdate(currentModeId: "fast"), to: &turn)
        TranscriptReducer.apply(.userMessageChunk(.text("echo")), to: &turn)
        #expect(turn.plan?.entries.count == 1)
        #expect(turn.entries.isEmpty)
    }

    @Test("Final answer is the trailing text; earlier entries collapse")
    func finalVersusWorked() {
        let turn = reduce([
            .agentMessageChunk(.text("thinking out loud")),
            .toolCall(ToolCall(toolCallId: "a", title: "Read")),
            .agentMessageChunk(.text("Here is the answer."))
        ])
        #expect(turn.finalText == .text(id: "t1", markdown: "Here is the answer."))
        #expect(turn.workedEntries.map(\.id) == ["text:t0", "tool:a"])
        #expect(turn.hasWorkedContent)
        #expect(turn.toolCalls.count == 1)
    }

    @Test("A turn ending on a tool call still exposes the last text answer")
    func endsOnTool() {
        let turn = reduce([
            .agentMessageChunk(.text("working")),
            .toolCall(ToolCall(toolCallId: "a", title: "Run"))
        ])
        #expect(turn.finalText == .text(id: "t0", markdown: "working"))
        #expect(turn.workedEntries.map(\.id) == ["tool:a"])
    }

    @Test("Duration computes from start and end timestamps")
    func duration() {
        let start = Date(timeIntervalSince1970: 1000)
        var turn = AssistantTurn(startedAt: start, endedAt: start.addingTimeInterval(12))
        #expect(turn.duration == 12)
        turn.endedAt = nil
        #expect(turn.duration == nil)
    }
}
