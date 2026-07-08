import Foundation
import Testing
import ACPKit
@testable import HerdManCore

/// The flush-batch coalescing and adaptive pacing helpers: pure functions,
/// but they sit on the hottest path in the app (every streamed token).
@MainActor
@Suite("SessionModel stream pacing")
struct SessionModelStreamPacingTests {
    private func chunk(
        _ text: String,
        messageId: String? = "m1",
        parent: String? = nil,
        phase: MessagePhase? = nil
    ) -> ServerSessionStreamEvent {
        .update(.agentMessageChunk(.text(text), messageId: messageId, parentToolCallId: parent, phase: phase))
    }

    @Test("Adjacent same-span text chunks merge into one")
    func adjacentChunksMerge() {
        let merged = SessionModel.coalesced([chunk("Hel"), chunk("lo "), chunk("world")])
        #expect(merged == [chunk("Hello world")])
    }

    @Test("Chunks for different spans, parents, or phases stay separate")
    func differentTargetsDoNotMerge() {
        let events = [
            chunk("a", messageId: "m1"),
            chunk("b", messageId: "m2"),
            chunk("c", messageId: "m2", parent: "tool-1"),
            chunk("d", messageId: "m2", parent: "tool-1", phase: .commentary)
        ]
        #expect(SessionModel.coalesced(events) == events)
    }

    @Test("Zero-length retro-tag chunks never merge")
    func retroTagChunksStaySeparate() {
        let events = [chunk("preamble"), chunk("", phase: .commentary), chunk("answer")]
        #expect(SessionModel.coalesced(events) == events)
    }

    @Test("Non-text events break a merge run and are preserved in order")
    func nonTextEventsPreserved() {
        let finished = ServerSessionStreamEvent.finished(.endTurn)
        let events = [chunk("a"), chunk("b"), finished, chunk("c"), chunk("d")]
        #expect(SessionModel.coalesced(events) == [chunk("ab"), finished, chunk("cd")])
    }

    @Test("Coalescing merged chunks applies identically to applying them singly")
    func mergePreservesReducedTranscript() {
        var merged = AssistantTurn()
        var single = AssistantTurn()
        let updates: [SessionUpdate] = [
            .agentMessageChunk(.text("Hello "), messageId: "m1", parentToolCallId: nil, phase: nil),
            .agentMessageChunk(.text("world"), messageId: "m1", parentToolCallId: nil, phase: nil)
        ]
        for update in updates {
            TranscriptReducer.apply(update, to: &single)
        }
        for case let .update(update) in SessionModel.coalesced(updates.map { .update($0) }) {
            TranscriptReducer.apply(update, to: &merged)
        }
        #expect(merged.entries == single.entries)
    }

    @Test("Flush interval stretches with streamed size and keeps the zero test hook")
    func adaptiveFlushInterval() {
        let base = Duration.milliseconds(16)
        #expect(SessionModel.flushInterval(base: base, streamedBytes: 0) == base)
        #expect(SessionModel.flushInterval(base: base, streamedBytes: 48 * 1024 - 1) == base)
        #expect(SessionModel.flushInterval(base: base, streamedBytes: 48 * 1024) == base * 2)
        #expect(SessionModel.flushInterval(base: base, streamedBytes: 144 * 1024) == base * 3)
        // The tests-only zero interval must stay zero at any size.
        #expect(SessionModel.flushInterval(base: .zero, streamedBytes: 1_000_000) == .zero)
    }
}
