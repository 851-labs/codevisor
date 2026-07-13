import Foundation
import Testing
import ACPKit
@testable import HerdManCore

@Suite("ToolCall diff totals")
struct ToolCallDiffTotalsTests {
    @Test("Streamed diffStats win over content diffs")
    func statsPrecedence() {
        let call = ToolCall(
            toolCallId: "t",
            title: "Edit",
            kind: .edit,
            content: [.diff(path: "/a", oldText: "one\n", newText: "one\ntwo\n")],
            diffStats: [ToolCallDiffStat(path: "/a", added: 13, removed: 7)]
        )
        #expect(call.diffTotals == LineDiff.Totals(added: 13, removed: 7))
    }

    @Test("Multi-file stats sum across paths")
    func multiFileSum() {
        let call = ToolCall(
            toolCallId: "t",
            title: "Edit",
            diffStats: [
                ToolCallDiffStat(path: "/a", added: 3, removed: 1),
                ToolCallDiffStat(path: "/b", added: 2, removed: 4)
            ]
        )
        #expect(call.diffTotals == LineDiff.Totals(added: 5, removed: 5))
    }

    @Test("Content diffs are computed when no stats are present")
    func contentFallback() {
        let call = ToolCall(
            toolCallId: "t",
            title: "Edit",
            content: [
                .diff(path: "/a", oldText: "one\n", newText: "one\ntwo\n"),
                .diff(path: "/b", oldText: "x\n", newText: "y\n")
            ]
        )
        #expect(call.diffTotals == LineDiff.Totals(added: 2, removed: 1))
    }

    @Test("Calls without diff data have no totals")
    func noData() {
        #expect(ToolCall(toolCallId: "t", title: "Read", kind: .read).diffTotals == nil)
        #expect(ToolCall(toolCallId: "t", title: "Run", content: [.content(.text("out"))]).diffTotals == nil)
    }

    @Test("Bare edit titles become a progress placeholder until data arrives")
    func displayTitle() {
        // Bare tool name, running, no data → placeholder.
        #expect(ToolCall(toolCallId: "t", title: "Edit", kind: .edit, status: .inProgress).displayTitle == "Editing file…")
        #expect(ToolCall(toolCallId: "t", title: "", kind: .edit, status: .inProgress).displayTitle == "Editing file…")
        // A real phrase passes through even without data.
        #expect(ToolCall(toolCallId: "t", title: "Editing README.md", kind: .edit, status: .inProgress).displayTitle == "Editing README.md")
        // Once diff stats exist, the adapter title stands.
        #expect(ToolCall(
            toolCallId: "t", title: "Edit", kind: .edit, status: .inProgress,
            diffStats: [ToolCallDiffStat(path: "a", added: 1, removed: 0)]
        ).displayTitle == "Edit")
        // Settled calls always show their final title.
        #expect(ToolCall(toolCallId: "t", title: "Edit", kind: .edit, status: .completed).displayTitle == "Edit")
        // Non-edit calls are untouched (empty falls back generically).
        #expect(ToolCall(toolCallId: "t", title: "Ran ls", kind: .execute, status: .inProgress).displayTitle == "Ran ls")
        #expect(ToolCall(toolCallId: "t", title: "", kind: .execute, status: .inProgress).displayTitle == "Working…")
    }

    @Test("HerdMan gateway names become semantic action titles across harnesses")
    func gatewayDisplayTitle() {
        #expect(ToolCall(
            toolCallId: "claude", title: "herdman.search", status: .completed,
            rawInput: ["query": "Sentry"]
        ).displayTitle == "Searched integrations for Sentry")
        #expect(ToolCall(
            toolCallId: "codex", title: "mcp__herdman__execute", status: .inProgress,
            rawInput: ["tool": "find_organizations"]
        ).displayTitle == "Running find organizations…")
        #expect(ToolCall(
            toolCallId: "acp", title: "herdman_describe", status: .completed,
            rawInput: ["tool": "search_issues"]
        ).displayTitle == "Inspected search issues")
        #expect(ToolCall(
            toolCallId: "code", title: "herdman.run_code", status: .completed
        ).displayTitle == "Ran an integration workflow")
        #expect(ToolCall(
            toolCallId: "search", title: "ToolSearch", status: .completed
        ).displayTitle == "Searched available tools")
    }
}
