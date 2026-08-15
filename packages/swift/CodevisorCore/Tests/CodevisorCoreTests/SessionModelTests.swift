import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("SessionModel")
struct SessionModelTests {
    init() {
        // Production coalesces stream events into per-frame batches; these
        // tests settle with `Task.yield()` loops that never advance the wall
        // clock, so flush on the next main-actor turn instead.
        SessionModel.eventFlushInterval = .zero
        SessionModel.cancellationTerminalEventWaitDelay = .zero
    }

    @Test("A message created before model connection retains its identity")
    func precreatedMessageRetainsIdentity() async {
        let sessionId = UUID()
        let messageId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        var locallyAppendedID: UUID?
        model.onLocalUserMessageAppended = { locallyAppendedID = $0 }

        await model.send(UserMessage(id: messageId, text: "  run pwd  "))

        let sent = try! #require(userMessages(model).first)
        #expect(sent.id == messageId)
        #expect(sent.text == "run pwd")
        #expect(locallyAppendedID == messageId)
        #expect(client.promptedMessageIds == [messageId.uuidString.lowercased()])
    }

    @Test("The optimistic message is visible before prompt transport completes")
    func optimisticMessagePrecedesTransportCompletion() async {
        let sessionId = UUID()
        let messageId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let (gate, releasePrompt) = AsyncStream.makeStream(of: Void.self)
        client.holdPrompts(until: gate)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        var locallyAppendedID: UUID?
        model.onLocalUserMessageAppended = { locallyAppendedID = $0 }

        let send = Task {
            await model.send(UserMessage(id: messageId, text: "show this now"))
        }
        await settleUntil {
            locallyAppendedID == messageId && client.promptedMessageIds.count == 1
        }

        #expect(userMessages(model).map(\.id) == [messageId])
        #expect(locallyAppendedID == messageId)
        #expect(client.promptedMessageIds == [messageId.uuidString.lowercased()])

        releasePrompt.yield()
        releasePrompt.finish()
        await send.value
    }

    @Test("The prompt carries the optimistic message id; the echo reconciles by identity")
    func echoReconcilesByIdentity() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.send("run pwd")
        let optimisticId = userMessages(model).first!.id
        // The wire carried the optimistic id.
        #expect(client.promptedMessageIds == [optimisticId.uuidString.lowercased()])
        // The echo comes back with that id — EVEN with different text (the
        // server may normalize whitespace), identity wins and nothing dups.
        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-18T00:00:00.000Z",
                payload: .object([
                    "role": .string("user"),
                    "messageId": .string(optimisticId.uuidString.lowercased()),
                    "text": .string("run  pwd"),
                ])
            ))
        client.emit(
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-18T00:00:01.000Z",
                payload: .object(["stopReason": .string("end_turn")])
            ))
        await settleUntil { !model.isSending }
        #expect(userMessages(model).count == 1)
        #expect(userMessages(model).first?.text == "run pwd")
    }

    @Test("Retry starts a new assistant attempt without duplicating the user message")
    func retryResponseDoesNotDuplicateUserMessage() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.send("finish the change")
        await settleUntil { !model.isSending }
        let original = try! #require(userMessages(model).first)
        await model.retryResponse(to: original)
        await settleUntil { !model.isSending }

        #expect(
            client.promptedTexts == [
                "finish the change",
                "Continue from the failed attempt without repeating completed work.",
            ])
        #expect(
            client.promptedMessageIds == [
                original.id.uuidString.lowercased(),
                original.id.uuidString.lowercased(),
            ])
        #expect(userMessages(model).map(\.text) == ["finish the change"])
        #expect(
            model.conversation.filter {
                if case .assistant = $0 { return true }
                return false
            }.count == 2)
    }

    @Test("A user echo after an agent restart never duplicates the message")
    func echoAfterAgentRestartDedupes() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.send("run pwd")
        // The harness dies right after the prompt (e.g. codex app-server
        // exiting on its first spawn) — the active bubble is torn down…
        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.error",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-18T00:00:00.000Z",
                payload: .object(["message": .string("codex app-server exited")])
            ))
        // …and the reconnected stream then delivers the server's echo of
        // the message. It must stamp onto the optimistic append, not
        // duplicate it.
        client.emit(
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-07-18T00:00:01.000Z",
                payload: .object([
                    "role": .string("user"),
                    "messageId": .string(UUID().uuidString),
                    "text": .string("run pwd"),
                ])
            ))
        await settleUntil { model.errorMessage != nil }
        #expect(userMessages(model).count == 1)
    }

    @Test("Blank prompts are ignored")
    func blankIgnored() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.send("   ")
        #expect(model.conversation.isEmpty)
        #expect(client.promptedTexts.isEmpty)
    }

    @Test("cancel is ignored unless a turn is in flight")
    func cancelOnlyWhileSending() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.cancel()
        #expect(client.cancelCount == 0)
    }

    @Test("Cancellation is single-flight and clears on the terminal event")
    func cancellationIsSingleFlight() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.send("keep working")
        #expect(model.isSending)

        async let first: Void = model.cancel()
        for _ in 0..<100 {
            await Task.yield()
            if client.cancelCount == 1 { break }
        }
        async let duplicate: Void = model.cancel()
        client.emit(stopEnvelope(id: 9, sessionId: sessionId, stopReason: "cancelled"))
        _ = await (first, duplicate)

        #expect(client.cancelCount == 1)
        #expect(model.isSending == false)
        #expect(model.isCancelling == false)
    }

    @Test("Missed live cancellation terminal reconciles from durable history")
    func cancellationReconcilesFromDurableHistory() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.send("keep working")
        #expect(model.isSending)
        client.initialTranscriptPage = cancellationTranscriptPage(
            sessionId: sessionId,
            isGenerating: false,
            stopReason: "cancelled"
        )

        await model.cancel()

        #expect(client.cancelCount == 1)
        #expect(model.isSending == false)
        #expect(model.errorMessage == nil)
    }

    @Test("Successful cancellation with a generating snapshot surfaces recovery")
    func cancellationGeneratingSnapshotSurfacesRecovery() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await model.send("keep working")
        client.initialTranscriptPage = cancellationTranscriptPage(
            sessionId: sessionId,
            isGenerating: true,
            stopReason: nil
        )

        await model.cancel()

        #expect(model.isSending)
        #expect(model.errorMessage?.contains("server still reports this turn as running") == true)
    }

    @Test("Quiet turns surface a non-destructive stalled state")
    func quietTurnSurfacesStalledState() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            stalledTurnQuietInterval: .zero
        )

        await model.send("wait quietly")
        await settleUntil { model.isTakingLongerThanExpected }

        #expect(model.isSending)
        #expect(model.providerActivityPhase == .modelStream)
        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(message.turn.isThinking == false)
        client.emit(stopEnvelope(id: 10, sessionId: sessionId, stopReason: "end_turn"))
        await settleUntil { !model.isSending }
        #expect(model.isTakingLongerThanExpected == false)
        #expect(model.providerActivityPhase == nil)
    }

    /// Regression guard for the observable-write guards in
    /// `noteProviderActivity`. Those two writes are guarded so streaming stops
    /// re-rendering the composer on every chunk — but the quiet-turn timer
    /// underneath them must still be cancelled and re-armed per event. Guarding
    /// the whole function on a phase change instead (the obvious refactor)
    /// leaves the task armed by the FIRST chunk of a phase, so a turn that
    /// streams steadily under one phase reports itself stalled mid-stream.
    ///
    /// Wall-clock by necessity: the bug is about *when* the timer fires, so the
    /// quiet window has to elapse for real. Margins are ~16x the pump interval.

    @Test("Steady same-phase activity keeps re-arming the quiet-turn timer")
    func steadyActivityNeverReportsStalled() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let quietInterval = Duration.milliseconds(200)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            stalledTurnQuietInterval: quietInterval
        )

        // `send` itself notes .modelStream activity, arming the first window.
        await model.send("stream steadily")

        // Pump chunks under the SAME phase for well past one quiet window.
        for id in 1...16 {
            try? await Task.sleep(for: .milliseconds(30))
            client.emit(
                ServerEventEnvelope(
                    id: id,
                    serverId: "local",
                    kind: "session.output",
                    subjectId: sessionId.uuidString,
                    createdAt: "2026-06-30T00:00:02.000Z",
                    payload: .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "messageId": .string("msg-1"),
                        "content": .object(["type": .string("text"), "text": .string("chunk ")]),
                    ])
                ))
            // Let the buffered flush apply the chunk (the suite flushes on the
            // next main-actor turn), then check the state it produced.
            for _ in 0..<8 { await Task.yield() }
            #expect(
                model.isTakingLongerThanExpected == false,
                "a steadily streaming turn must never report itself stalled (chunk \(id))"
            )
        }

        #expect(model.isSending)
        #expect(model.providerActivityPhase == .modelStream)

        // With activity stopped, the window is allowed to elapse as usual.
        try? await Task.sleep(for: quietInterval + .milliseconds(150))
        #expect(model.isTakingLongerThanExpected)
    }

    @Test("Attachments allow empty text and ride the prompt to the server")
    func attachmentsRidePrompt() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        let attachment = Attachment(
            fileId: "file-1", name: "shot.png", mimeType: "image/png", sizeBytes: 3, kind: .image
        )

        await model.send("", attachments: [attachment])

        #expect(client.promptedTexts == [""])
        #expect(client.promptedAttachments == [[attachment.serverRef]])
        guard case let .user(user) = model.conversation.first else {
            Issue.record("expected user")
            return
        }
        #expect(user.attachments == [attachment])
    }
}
