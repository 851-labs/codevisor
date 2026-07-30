import ACPKit
import Testing
@testable import CodevisorUI

@Suite("Tool group disclosure policy")
struct ToolGroupDisclosurePolicyTests {
    @Test("An unfinished call keeps a group expanded after prose follows")
    func unfinishedCallKeepsGroupExpanded() {
        let calls = [
            ToolCall(toolCallId: "read", title: "Read", status: .completed),
            ToolCall(toolCallId: "command", title: "Run command", status: .inProgress)
        ]

        #expect(ToolGroupDisclosurePolicy.shouldAutoExpand(calls, followsLatestWork: false))
        #expect(ToolGroupDisclosurePolicy.isExpanded(calls, disclosureExpansion: false))
    }

    @Test("Every non-terminal status keeps a group expanded")
    func nonTerminalStatusesKeepGroupExpanded() {
        for status in [ToolCallStatus?.none, .some(.pending), .some(.inProgress)] {
            let call = ToolCall(toolCallId: "call", title: "Tool", status: status)
            #expect(ToolGroupDisclosurePolicy.hasUnsettledCall([call]))
        }
    }

    @Test("A non-trailing group may collapse after every call reaches a terminal state")
    func terminalGroupMayCollapse() {
        let calls = [
            ToolCall(toolCallId: "completed", title: "Completed", status: .completed),
            ToolCall(toolCallId: "failed", title: "Failed", status: .failed),
            ToolCall(toolCallId: "cancelled", title: "Cancelled", status: .cancelled)
        ]

        #expect(!ToolGroupDisclosurePolicy.hasUnsettledCall(calls))
        #expect(!ToolGroupDisclosurePolicy.shouldAutoExpand(calls, followsLatestWork: false))
        #expect(ToolGroupDisclosurePolicy.shouldAutoExpand(calls, followsLatestWork: true))
    }
}
