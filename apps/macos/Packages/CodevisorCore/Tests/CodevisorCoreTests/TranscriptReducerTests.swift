import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

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

    @Test("Commentary-tagged spans never become the final answer")
    func commentaryPhaseExcludedFromFinal() {
        let turn = reduce([
            .agentMessageChunk(.text("Checking the tests."), messageId: "m1", parentToolCallId: nil, phase: .commentary),
            .toolCall(ToolCall(toolCallId: "a", title: "Run tests", kind: .execute, status: .completed)),
            .agentMessageChunk(.text("They pass."), messageId: "m2", parentToolCallId: nil, phase: .final)
        ])
        #expect(turn.finalText == .text(id: "acp:m2", markdown: "They pass."))
        #expect(turn.workedEntries.map(\.id) == ["text:acp:m1", "tool:a"])
    }

    @Test("A zero-length phase chunk retro-tags an already streamed span")
    func retroactiveCommentaryDemotion() {
        var turn = AssistantTurn(isGenerating: true)
        // Claude preamble streams untagged: it is the optimistic candidate.
        TranscriptReducer.apply(.agentMessageChunk(.text("Let me check."), messageId: "m1"), to: &turn)
        #expect(turn.finalText == .text(id: "acp:m1", markdown: "Let me check."))
        // A tool call starting in the same message demotes it via a
        // zero-length correction chunk — the candidate slot empties…
        TranscriptReducer.apply(
            .agentMessageChunk(.text(""), messageId: "m1", parentToolCallId: nil, phase: .commentary),
            to: &turn
        )
        TranscriptReducer.apply(
            .toolCall(ToolCall(toolCallId: "a", title: "Run tests", kind: .execute, status: .inProgress)),
            to: &turn
        )
        #expect(turn.finalText == nil)
        #expect(turn.workedEntries.map(\.id) == ["text:acp:m1", "tool:a"])
        // …until the real answer streams in a fresh message.
        TranscriptReducer.apply(.agentMessageChunk(.text("Tests pass."), messageId: "m2"), to: &turn)
        #expect(turn.finalText == .text(id: "acp:m2", markdown: "Tests pass."))
    }

    @Test("A final-tagged span stays the answer across trailing tool calls")
    func finalPhaseSurvivesTrailingTools() {
        let turn = reduce([
            .agentMessageChunk(.text("Done."), messageId: "m1", parentToolCallId: nil, phase: .final),
            .toolCall(ToolCall(toolCallId: "a", title: "Cleanup", kind: .execute, status: .completed))
        ])
        #expect(turn.finalText == .text(id: "acp:m1", markdown: "Done."))
    }

    @Test("Only a final-tagged candidate counts as asserted")
    func finalTextAssertion() {
        var turn = AssistantTurn(isGenerating: true)
        // Optimistic candidate (no phase): not asserted — could still demote.
        TranscriptReducer.apply(.agentMessageChunk(.text("maybe"), messageId: "m1"), to: &turn)
        #expect(turn.finalTextIsAsserted == false)
        // Provider-asserted final answer: certainty from the first chunk.
        TranscriptReducer.apply(
            .agentMessageChunk(.text("Done."), messageId: "m2", parentToolCallId: nil, phase: .final),
            to: &turn
        )
        #expect(turn.finalTextIsAsserted)
        #expect(turn.finalText == .text(id: "acp:m2", markdown: "Done."))
    }

    @Test("Subagent chunk phases do not affect the main turn's final answer")
    func subagentPhaseIgnored() {
        let turn = reduce([
            .agentMessageChunk(.text("main answer")),
            .agentMessageChunk(.text("child note"), messageId: "msg-sub", parentToolCallId: "task-1")
        ])
        #expect(turn.finalText == .text(id: "t0", markdown: "main answer"))
        #expect(turn.textPhases.isEmpty)
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

    @Test("Context compaction updates in place and preserves arrival order")
    func contextCompaction() {
        var turn = AssistantTurn(isGenerating: true, isThinking: true)
        TranscriptReducer.apply(
            .toolCall(ToolCall(toolCallId: "before", title: "Before")),
            to: &turn
        )
        TranscriptReducer.apply(.contextCompaction(id: "compact-1", status: .started), to: &turn)
        #expect(turn.contextCompactionStatus == .started)
        #expect(turn.isThinking == false)
        TranscriptReducer.apply(
            .toolCall(ToolCall(toolCallId: "after", title: "After")),
            to: &turn
        )

        TranscriptReducer.apply(.contextCompaction(id: "compact-1", status: .completed), to: &turn)
        #expect(turn.contextCompactionStatus == .completed)
        #expect(turn.entries.count == 3)
        guard case let .contextCompaction(id, status) = turn.entries[1] else {
            Issue.record("expected compaction between tool calls")
            return
        }
        #expect(id == "compact-1")
        #expect(status == .completed)
    }

    @Test("Failed and legacy compactions settle the matching ordered entry")
    func failedAndLegacyContextCompaction() {
        var turn = AssistantTurn(isGenerating: true)
        TranscriptReducer.apply(.contextCompaction(id: nil, status: .started), to: &turn)
        TranscriptReducer.apply(.contextCompaction(id: nil, status: .completed), to: &turn)
        #expect(turn.entries.count == 1)
        #expect(turn.contextCompactionStatus == .completed)

        TranscriptReducer.apply(.contextCompaction(id: "compact-2", status: .started), to: &turn)
        #expect(turn.entries.count == 2)
        TranscriptReducer.apply(.contextCompaction(id: "compact-2", status: .failed), to: &turn)
        #expect(turn.entries.count == 1)
        #expect(turn.contextCompactionStatus == .completed)

        TranscriptReducer.apply(.contextCompaction(id: nil, status: .failed), to: &turn)
        #expect(turn.entries.isEmpty)
        #expect(turn.contextCompactionStatus == nil)
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

    @Test("Plan documents replace per turn and quiet the thinking state")
    func planDocument() {
        var turn = AssistantTurn(isThinking: true)
        TranscriptReducer.apply(.planDocument(markdown: "# Draft"), to: &turn)
        #expect(turn.planDocument == "# Draft")
        #expect(turn.isThinking == false)
        // A later document replaces the first; the step plan is independent.
        TranscriptReducer.apply(.planDocument(markdown: "# Final Plan"), to: &turn)
        TranscriptReducer.apply(.plan(Plan(entries: [PlanEntry(content: "step", priority: .medium, status: .inProgress)])), to: &turn)
        #expect(turn.planDocument == "# Final Plan")
        #expect(turn.plan?.entries.count == 1)
        #expect(turn.entries.isEmpty)
    }

    @Test("Resolved questions become one inline tool-call row per id")
    func answeredQuestions() {
        var turn = AssistantTurn()
        let resolution = QuestionResolution(
            questionId: "q-1",
            outcome: .answered,
            questions: [QuestionSpec(id: "a", question: "Pick one")],
            answers: ["a": QuestionAnswerEntry(answers: ["Option A"])]
        )
        TranscriptReducer.apply(.questionResolved(resolution), to: &turn)
        // Replay delivers the pair again; the row must upsert, not duplicate.
        TranscriptReducer.apply(.questionResolved(resolution), to: &turn)
        TranscriptReducer.apply(.question(QuestionRequest(questionId: "q-2", questions: [])), to: &turn)
        #expect(turn.entries.count == 1)
        guard case let .tool(call) = turn.entries.first else {
            Issue.record("expected a synthesized question tool call")
            return
        }
        #expect(call.toolCallId == "question:q-1")
        #expect(call.kind == .question)
        #expect(call.title == "Pick one")
        #expect(call.content == [.content(.text("Option A"))])
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

    @Test("A full tool_call re-send preserves streamed diffStats and content it omits")
    func resendPreservesStreamedState() {
        let turn = reduce([
            .toolCall(ToolCall(toolCallId: "a", title: "Edit", kind: .edit, status: .pending)),
            .toolCallUpdate(ToolCallUpdate(
                toolCallId: "a",
                diffStats: [ToolCallDiffStat(path: "/a", added: 5, removed: 2)]
            )),
            .toolCall(ToolCall(toolCallId: "a", title: "Edited a.txt", kind: .edit, status: .completed))
        ])
        guard case let .tool(call) = turn.entries.first else {
            Issue.record("expected tool entry")
            return
        }
        #expect(call.title == "Edited a.txt")
        #expect(call.status == .completed)
        #expect(call.diffStats == [ToolCallDiffStat(path: "/a", added: 5, removed: 2)])
    }

    // MARK: - Subagent routing

    @Test("Parented chunks land in the subagent bucket without touching main state")
    func subagentChunksRouted() {
        let turn = reduce([
            .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: explore", kind: .agent, status: .inProgress)),
            .agentThoughtChunk(.text("hmm"), messageId: nil, parentToolCallId: "task-1"),
            .agentMessageChunk(.text("child "), messageId: "msg-sub", parentToolCallId: "task-1"),
            .agentMessageChunk(.text("text"), messageId: "msg-sub", parentToolCallId: "task-1")
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
        TranscriptReducer.apply(.agentThoughtChunk(.text("child hmm"), messageId: nil, parentToolCallId: "task-1"), to: &turn)
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
            .agentMessageChunk(.text("main text"))
        ])
        #expect(turn.subagents["task-1"]?.entries == [.text(id: "t0", markdown: "one more")])
        #expect(turn.subagents["task-2"]?.entries == [.text(id: "t0", markdown: "two ")])
        #expect(turn.entries.map(\.id) == ["tool:task-1", "tool:task-2", "text:t0"])
    }

    @Test("Parented tool calls nest; unparented updates settle them by id lookup")
    func childToolSettleByLookup() {
        let turn = reduce([
            .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: explore", kind: .agent)),
            .toolCall(ToolCall(toolCallId: "sub-read", title: "Read", kind: .read, status: .inProgress, parentToolCallId: "task-1")),
            // Settle updates (tool results) carry no parent attribution.
            .toolCallUpdate(ToolCallUpdate(toolCallId: "sub-read", status: .completed))
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
            .toolCall(ToolCall(toolCallId: "task-2", title: "Agent: inner", kind: .agent, status: .inProgress, parentToolCallId: "task-1")),
            .toolCall(ToolCall(toolCallId: "sub-run", title: "Run", kind: .execute, status: .inProgress, parentToolCallId: "task-2"))
        ])
        TranscriptReducer.apply(.agentThoughtChunk(.text("x"), messageId: nil, parentToolCallId: "task-2"), to: &turn)
        TranscriptReducer.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "task-1", status: .completed)), to: &turn)

        guard case let .tool(inner)? = turn.subagents["task-1"]?.entries.first,
              case let .tool(grandchild)? = turn.subagents["task-2"]?.entries.first else {
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
            .toolCall(ToolCall(toolCallId: "sub-read", title: "Read", kind: .read, status: .inProgress, parentToolCallId: "task-1"))
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
            .toolCall(ToolCall(toolCallId: "main-run", title: "Run", kind: .execute))
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
            .toolCall(ToolCall(toolCallId: "broken", title: "Bash", status: .failed))
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

/// Covers `AssistantTurn.showsActivityIndicator` — the "Thinking…" gate. The
/// old gate was `isThinking` alone, a knife-edge cleared by the first non-thought
/// chunk and only re-armed by another thought chunk, so any lull between steps
/// (waiting on the model, or between tool calls) showed nothing and the chat
/// looked frozen.
@Suite("AssistantTurn activity indicator")
struct AssistantTurnActivityTests {
    @Test("A finished turn never shows the indicator")
    func settledTurn() {
        let turn = AssistantTurn(isGenerating: false, isThinking: false)
        #expect(!turn.showsActivityIndicator)
        // Even an explicit (stale) thinking flag can't light it once finished.
        let staleThinking = AssistantTurn(isGenerating: false, isThinking: true)
        #expect(!staleThinking.showsActivityIndicator)
    }

    @Test("A just-started turn with no output yet shows the indicator")
    func freshTurn() {
        let turn = AssistantTurn(isGenerating: true, isThinking: true)
        #expect(turn.showsActivityIndicator)
    }

    @Test("Explicit thought streaming always shows the indicator")
    func thoughtStreaming() {
        var turn = AssistantTurn(isGenerating: true, isThinking: false)
        TranscriptReducer.apply(.agentThoughtChunk(.text("hmm")), to: &turn)
        #expect(turn.isThinking)
        #expect(turn.showsActivityIndicator)
    }

    @Test("A streaming final answer suppresses the indicator (the text is the activity)")
    func streamingFinalAnswer() {
        var turn = AssistantTurn(isGenerating: true)
        TranscriptReducer.apply(.agentMessageChunk(.text("The answer is 42.")), to: &turn)
        #expect(!turn.isThinking)
        #expect(turn.finalText != nil)
        #expect(!turn.showsActivityIndicator)
    }

    @Test("A running tool call suppresses the indicator (its card shows progress)")
    func runningTool() {
        var turn = AssistantTurn(isGenerating: true)
        TranscriptReducer.apply(
            .toolCall(ToolCall(toolCallId: "t1", title: "Read", kind: .read, status: .inProgress)),
            to: &turn
        )
        #expect(turn.hasRunningToolCall)
        #expect(!turn.showsActivityIndicator)
    }

    @Test("The lull after a tool settles — preamble demoted, nothing running — shows the indicator")
    func gapAfterToolSettles() {
        var turn = AssistantTurn(isGenerating: true)
        // Preamble streams as the optimistic final-answer candidate…
        TranscriptReducer.apply(.agentMessageChunk(.text("Let me check."), messageId: "m1"), to: &turn)
        // …a tool call demotes it to commentary via a zero-length retro-tag…
        TranscriptReducer.apply(
            .agentMessageChunk(.text(""), messageId: "m1", parentToolCallId: nil, phase: .commentary),
            to: &turn
        )
        TranscriptReducer.apply(
            .toolCall(ToolCall(toolCallId: "t1", title: "Read", kind: .read, status: .inProgress)),
            to: &turn
        )
        // …then the tool completes. Model is now deciding the next step with
        // nothing streaming: previously this window showed nothing (looked stuck).
        TranscriptReducer.apply(
            .toolCallUpdate(ToolCallUpdate(toolCallId: "t1", status: .completed)),
            to: &turn
        )
        #expect(!turn.hasRunningToolCall)
        #expect(turn.finalText == nil)
        #expect(turn.showsActivityIndicator)
    }
}
