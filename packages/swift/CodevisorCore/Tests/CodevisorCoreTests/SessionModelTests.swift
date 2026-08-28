import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("SessionModel")
struct SessionModelTests {
    init() {
        // Production coalesces stream events into per-frame batches; these
        // tests should not wait on the production frame cadence, so flush on
        // the next main-actor turn instead.
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
        await settleUntil { client.cancelCount == 1 }
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

    @Test("Recovery reconciles only the turns that need it")
    func recoveryReconcileGuards() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        client.initialTranscriptPage = cancellationTranscriptPage(
            sessionId: sessionId,
            isGenerating: true,
            stopReason: nil,
            text: "partial answer"
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        // Idle: neither recovery hook touches the server.
        await model.reconcileIfInFlight()
        await model.reconcileIfStalled()
        #expect(client.transcriptPageRequests.isEmpty)

        await model.send("keep working")
        #expect(model.isSending)
        let baseline = client.transcriptPageRequests.count

        // Streaming healthily (not stalled): re-entry must not restart the
        // consumer on every navigation.
        await model.reconcileIfStalled()
        #expect(client.transcriptPageRequests.count == baseline)

        // Foreground recovery re-verifies any in-flight turn; durable history
        // still reports it live, so the reload is non-destructive.
        await model.reconcileIfInFlight()
        #expect(client.transcriptPageRequests.count == baseline + 1)
        #expect(model.isSending)

        // Once stalled, re-entry heals a turn that finished on the server.
        model.isTakingLongerThanExpected = true
        client.initialTranscriptPage = cancellationTranscriptPage(
            sessionId: sessionId,
            isGenerating: false,
            stopReason: "interrupted",
            text: "partial answer"
        )
        await model.reconcileIfStalled()
        #expect(model.isSending == false)
        #expect(model.isTakingLongerThanExpected == false)
    }

    @Test("Quiet turns surface a non-destructive stalled state")
    func quietTurnSurfacesStalledState() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let sleeper = ManualSessionSleeper()
        client.echoOnPrompt = false
        // The stall's automatic reconcile re-reads durable history; a page
        // still reporting a live turn must leave the stalled state intact.
        // Non-empty text so the reloaded item is streaming, not "thinking",
        // matching the placeholder it replaces.
        client.initialTranscriptPage = cancellationTranscriptPage(
            sessionId: sessionId,
            isGenerating: true,
            stopReason: nil,
            text: "partial answer"
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            stalledTurnQuietInterval: .seconds(300),
            quietTurnSleep: { try await sleeper.sleep(for: $0) }
        )

        await model.send("wait quietly")
        await sleeper.waitForCallCount(1)
        sleeper.advance()
        await settleUntil {
            model.isTakingLongerThanExpected && !client.transcriptPageRequests.isEmpty
        }
        // The stall consulted durable history instead of only flagging.
        #expect(client.transcriptPageRequests.count >= 1)

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
        sleeper.cancelAll()
    }

    /// Regression guard for the observable-write guards in
    /// `noteProviderActivity`. Those two writes are guarded so streaming stops
    /// re-rendering the composer on every chunk — but the quiet-turn timer
    /// underneath them must still be cancelled and re-armed per event. Guarding
    /// the whole function on a phase change instead (the obvious refactor)
    /// leaves the task armed by the FIRST chunk of a phase, so a turn that
    /// streams steadily under one phase reports itself stalled mid-stream.
    ///
    /// A manual sleeper keeps this about timer generations rather than runner
    /// scheduling: every chunk must replace the pending wait, and only the
    /// final generation is allowed to complete.

    @Test("Steady same-phase activity keeps re-arming the quiet-turn timer")
    func steadyActivityNeverReportsStalled() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let sleeper = ManualSessionSleeper()
        client.echoOnPrompt = false
        // Durable history for the stall's automatic reconcile: still live, so
        // the stalled state must survive the reload. The cursor covers every
        // chunk pumped below, exactly as a freshly fetched page would.
        client.initialTranscriptPage = cancellationTranscriptPage(
            sessionId: sessionId,
            isGenerating: true,
            stopReason: nil,
            eventCursor: 16
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString,
            stalledTurnQuietInterval: .seconds(300),
            quietTurnSleep: { try await sleeper.sleep(for: $0) }
        )

        // `send` itself notes .modelStream activity, arming the first window.
        await model.send("stream steadily")
        await sleeper.waitForCallCount(1)

        // Apply chunks under the SAME phase. Each one must cancel the current
        // sleep and arm a new generation even though the observable phase does
        // not change.
        for id in 1...16 {
            model.apply(
                .update(
                    .agentMessageChunk(
                        .text("chunk "),
                        messageId: "msg-1",
                        parentToolCallId: nil,
                        phase: nil
                    )))
            await sleeper.waitForCallCount(id + 1)
            #expect(
                model.isTakingLongerThanExpected == false,
                "a steadily streaming turn must never report itself stalled (chunk \(id))"
            )
        }

        #expect(model.isSending)
        #expect(model.providerActivityPhase == .modelStream)

        // Only the latest timer generation is allowed to declare the turn
        // quiet. No wall-clock duration is involved.
        sleeper.advance()
        await settleUntil { model.isTakingLongerThanExpected }
        model.endTurn()
        sleeper.cancelAll()
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
