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
}
