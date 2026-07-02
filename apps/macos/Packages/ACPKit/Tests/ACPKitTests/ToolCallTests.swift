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

    @Test("cancelled status round-trips and is terminal")
    func cancelledStatus() throws {
        let call = ToolCall(toolCallId: "t1", title: "Edit", status: .cancelled)
        let data = try ACPJSON.encoder.encode(call)
        let decoded = try ACPJSON.decoder.decode(ToolCall.self, from: data)
        #expect(decoded.status == .cancelled)
        #expect(decoded.isSettled)
        #expect(!ToolCall(toolCallId: "t1", title: "Edit", status: .inProgress).isSettled)
        #expect(!ToolCall(toolCallId: "t1", title: "Edit").isSettled)
    }

    @Test("Unknown status decodes to nil instead of dropping the call")
    func unknownStatusLenient() throws {
        let json = #"{"toolCallId":"x","title":"Run","status":"paused"}"#
        let call = try ACPJSON.decoder.decode(ToolCall.self, from: Data(json.utf8))
        #expect(call.toolCallId == "x")
        #expect(call.status == nil)
    }

    @Test("Unknown content elements are skipped, siblings kept")
    func unknownContentLenient() throws {
        let json = """
        {"toolCallId":"x","title":"Edit","content":[
            {"type":"hologram","data":"???"},
            {"type":"diff","path":"/a.txt","oldText":"1","newText":"2"}
        ]}
        """
        let call = try ACPJSON.decoder.decode(ToolCall.self, from: Data(json.utf8))
        #expect(call.content?.count == 1)
        guard case .diff(let path, _, _) = call.content?.first else {
            Issue.record("expected the diff to survive")
            return
        }
        #expect(path == "/a.txt")
    }

    @Test("diffStats decode on calls and updates, and merge like other fields")
    func diffStats() throws {
        let json = #"{"toolCallId":"x","title":"Edit","diffStats":[{"path":"/a","added":13,"removed":7}]}"#
        let call = try ACPJSON.decoder.decode(ToolCall.self, from: Data(json.utf8))
        #expect(call.diffStats == [ToolCallDiffStat(path: "/a", added: 13, removed: 7)])

        let updateJson = #"{"toolCallId":"x","diffStats":[{"path":"/a","added":14,"removed":7}]}"#
        let update = try ACPJSON.decoder.decode(ToolCallUpdate.self, from: Data(updateJson.utf8))
        let merged = call.applying(update)
        #expect(merged.diffStats?.first?.added == 14)

        // An update without stats preserves the existing ones.
        let untouched = merged.applying(ToolCallUpdate(toolCallId: "x", status: .completed))
        #expect(untouched.diffStats?.first?.added == 14)
        #expect(untouched.status == .completed)
    }
}
