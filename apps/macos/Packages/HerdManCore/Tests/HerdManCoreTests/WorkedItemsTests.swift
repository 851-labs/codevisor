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
}
