import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@Suite("Worked items grouping")
struct WorkedItemsTests {
    private func turn(_ entries: [TranscriptEntry]) -> AssistantTurn {
        AssistantTurn(entries: entries + [.text(id: "final", markdown: "final answer")])
    }

    private func tool(_ id: String, _ kind: ToolKind) -> TranscriptEntry {
        .tool(ToolCall(toolCallId: id, title: "Tool \(id)", kind: kind))
    }

    @Test("Consecutive tool calls collapse into one group")
    func grouping() {
        let result = turn([
            .text(id: "t0", markdown: "thinking"),
            tool("a", .read), tool("b", .read), tool("c", .search),
            .text(id: "t1", markdown: "more"),
            tool("d", .execute)
        ]).workedItems

        #expect(result.count == 4)
        #expect(result[0] == .text(id: "t0", markdown: "thinking"))
        if case let .toolGroup(_, calls) = result[1] { #expect(calls.count == 3) } else { Issue.record("expected group") }
        #expect(result[2] == .text(id: "t1", markdown: "more"))
        if case let .toolGroup(_, calls) = result[3] { #expect(calls.count == 1) } else { Issue.record("expected group") }
    }

    @Test("WorkedItem identities are unique")
    func ids() {
        let items = turn([.text(id: "x", markdown: "a"), tool("g", .read)]).workedItems
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test("An agent call breaks out of tool grouping as its own subagent item")
    func subagentBreaksGrouping() {
        let result = turn([
            tool("a", .read),
            tool("task-1", .agent),
            tool("b", .execute)
        ]).workedItems

        #expect(result.count == 3)
        if case let .toolGroup(_, calls) = result[0] { #expect(calls.map(\.toolCallId) == ["a"]) } else { Issue.record("expected group") }
        if case let .subagent(id, call) = result[1] {
            #expect(id == "task-1")
            #expect(call.kind == .agent)
        } else { Issue.record("expected subagent item") }
        if case let .toolGroup(_, calls) = result[2] { #expect(calls.map(\.toolCallId) == ["b"]) } else { Issue.record("expected group") }
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test("A call with a bucket becomes a subagent item even without the agent kind")
    func bucketImpliesSubagent() {
        var withBucket = turn([tool("task-x", .other)])
        withBucket.subagents["task-x"] = SubagentTranscript(entries: [.text(id: "t0", markdown: "hi")])
        guard case .subagent = withBucket.workedItems.first else {
            Issue.record("expected subagent item")
            return
        }
    }

    @Test("subagentItems groups a bucket's entries with the same rules")
    func nestedGrouping() {
        var base = turn([tool("task-1", .agent)])
        base.subagents["task-1"] = SubagentTranscript(entries: [
            .text(id: "t0", markdown: "child prose"),
            .tool(ToolCall(toolCallId: "sub-a", title: "Read", kind: .read)),
            .tool(ToolCall(toolCallId: "sub-b", title: "Grep", kind: .search)),
            .tool(ToolCall(toolCallId: "task-2", title: "Agent: nested", kind: .agent))
        ])
        let items = base.subagentItems("task-1")
        #expect(items.count == 3)
        #expect(items[0] == .text(id: "t0", markdown: "child prose"))
        if case let .toolGroup(_, calls) = items[1] { #expect(calls.count == 2) } else { Issue.record("expected group") }
        if case let .subagent(id, _) = items[2] { #expect(id == "task-2") } else { Issue.record("expected nested subagent") }
        #expect(base.subagentItems("unknown").isEmpty)
    }

    @Test("Summaries describe tool groups in first-seen order")
    func summaries() {
        #expect(ToolCallSummary.describe([call(.read), call(.read), call(.read)]) == "Read 3 files")
        #expect(ToolCallSummary.describe([call(.read)]) == "Read a file")
        #expect(ToolCallSummary.describe([call(.search), call(.execute), call(.execute)]) == "Searched code and ran 2 commands")
        #expect(ToolCallSummary.describe([call(.edit)]) == "Edited a file")
        #expect(ToolCallSummary.describe([]) == "")
    }

    @Test("Three or more phrases use an Oxford comma")
    func oxford() {
        let summary = ToolCallSummary.describe([call(.read), call(.search), call(.execute)])
        #expect(summary == "Read a file, searched code, and ran a command")
    }

    @Test("Symbol reflects the dominant tool kind")
    func symbols() {
        #expect(ToolCallSummary.symbol([call(.search), call(.search), call(.read)]) == "magnifyingglass")
        #expect(ToolCallSummary.symbol([call(.execute)]) == "terminal")
        #expect(ToolCallSummary.symbol([call(.edit)]) == "pencil")
        #expect(ToolCallSummary.symbol([call(.read)]) == "doc.text")
    }

    private func call(_ kind: ToolKind) -> ToolCall {
        ToolCall(toolCallId: UUID().uuidString, title: "t", kind: kind)
    }

    @Test("A tool group trails until non-empty text follows it")
    func trailingToolGroup() {
        var turn = AssistantTurn(isGenerating: true)
        TranscriptReducer.apply(.toolCall(ToolCall(toolCallId: "a", title: "Read")), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(toolCallId: "b", title: "Edit")), to: &turn)
        #expect(turn.isTrailingToolGroup(lastToolCallId: "b"))
        // Text after the group ends its trailing state; the group before it
        // was never trailing once "b" existed... but by id "a" is inside the
        // same run, so text is what flips it.
        TranscriptReducer.apply(.agentMessageChunk(.text("Now the answer.")), to: &turn)
        #expect(!turn.isTrailingToolGroup(lastToolCallId: "b"))
        // A later tool group trails again.
        TranscriptReducer.apply(.toolCall(ToolCall(toolCallId: "c", title: "Run")), to: &turn)
        #expect(turn.isTrailingToolGroup(lastToolCallId: "c"))
        #expect(!turn.isTrailingToolGroup(lastToolCallId: "missing"))
    }

    @Test("streamingItems keep strict arrival order including trailing text")
    func streamingItemsOrder() {
        var turn = AssistantTurn(isGenerating: true)
        TranscriptReducer.apply(.agentMessageChunk(.text("First I will check."), messageId: "m1"), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(toolCallId: "a", title: "Run", kind: .execute)), to: &turn)
        TranscriptReducer.apply(.agentMessageChunk(.text("Now editing."), messageId: "m2"), to: &turn)
        TranscriptReducer.apply(.toolCall(ToolCall(toolCallId: "b", title: "Edit", kind: .edit)), to: &turn)
        TranscriptReducer.apply(.agentMessageChunk(.text("Done."), messageId: "m3"), to: &turn)

        // Streaming view: everything in arrival order, nothing pulled out.
        #expect(turn.streamingItems.map(\.id) == [
            "wtext:acp:m1", "wgroup:a", "wtext:acp:m2", "wgroup:b", "wtext:acp:m3"
        ])
        // Finished view: the final text is split out below the worked section.
        #expect(turn.workedItems.map(\.id) == [
            "wtext:acp:m1", "wgroup:a", "wtext:acp:m2", "wgroup:b"
        ])
        #expect(turn.finalText == .text(id: "acp:m3", markdown: "Done."))
    }
}
