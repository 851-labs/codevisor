import Foundation
import Testing
@testable import ACPKit

@Suite("ToolCall merging")
struct ToolCallTests {
    @Test("applying merges only present fields")
    func applyingMerges() {
        let base = ToolCall(toolCallId: "t1", title: "Read file", kind: .read, status: .pending)
        let merged = base.applying(ToolCallUpdate(
            toolCallId: "t1",
            status: .completed,
            content: [.content(.text("done"))],
            locations: [ToolCallLocation(path: "/a", line: 3)],
            rawInput: ["path": "/a"],
            rawOutput: ["ok": true]
        ))
        #expect(merged.title == "Read file") // unchanged
        #expect(merged.kind == .read)        // unchanged
        #expect(merged.status == .completed) // updated
        #expect(merged.content?.count == 1)
        #expect(merged.locations?.first?.line == 3)
        #expect(merged.rawInput?["path"] == .string("/a"))
        #expect(merged.rawOutput?["ok"] == .bool(true))
    }

    @Test("applying can overwrite title and kind")
    func applyingTitleKind() {
        let base = ToolCall(toolCallId: "t1", title: "old", kind: .other)
        let merged = base.applying(ToolCallUpdate(toolCallId: "t1", title: "new", kind: .edit))
        #expect(merged.title == "new")
        #expect(merged.kind == .edit)
    }

    @Test("asToolCall supplies defaults for required fields")
    func asToolCall() {
        let fromUpdate = ToolCallUpdate(toolCallId: "t9", status: .inProgress).asToolCall()
        #expect(fromUpdate.toolCallId == "t9")
        #expect(fromUpdate.title == "")
        #expect(fromUpdate.status == .inProgress)
        #expect(fromUpdate.id == "t9")
    }

    @Test("ToolCall id mirrors toolCallId")
    func identity() {
        #expect(ToolCall(toolCallId: "abc", title: "t").id == "abc")
    }
}
