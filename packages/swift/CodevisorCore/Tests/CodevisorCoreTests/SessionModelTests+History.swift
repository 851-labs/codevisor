import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("Paginated history drops empty completed item shells from older servers")
    func paginatedHistoryDropsEmptyCompletedShells() throws {
        let sessionId = UUID()
        let visibleId = UUID()
        let rawPage = try JSONDecoder().decode(
            ServerTranscriptPage.self,
            from: Data(
                """
                {
                  "items": [
                    {
                      "id": "\(visibleId.uuidString)",
                      "sessionId": "\(sessionId.uuidString)",
                      "sequence": 0,
                      "role": "user",
                      "text": "visible",
                      "createdAt": "2026-08-12T00:00:00.000Z",
                      "updatedAt": "2026-08-12T00:00:00.000Z",
                      "isGenerating": false,
                      "hasDetails": false,
                      "revision": 1
                    },
                    {
                      "id": "\(UUID().uuidString)",
                      "sessionId": "\(sessionId.uuidString)",
                      "sequence": 1,
                      "role": "user",
                      "text": "",
                      "createdAt": "2026-08-12T00:00:01.000Z",
                      "updatedAt": "2026-08-12T00:00:01.000Z",
                      "isGenerating": false,
                      "hasDetails": false,
                      "revision": 1
                    },
                    {
                      "id": "\(UUID().uuidString)",
                      "sessionId": "\(sessionId.uuidString)",
                      "sequence": 2,
                      "role": "assistant",
                      "text": "",
                      "createdAt": "2026-08-12T00:00:02.000Z",
                      "updatedAt": "2026-08-12T00:00:02.000Z",
                      "isGenerating": false,
                      "hasDetails": false,
                      "revision": 1
                    }
                  ],
                  "hasMore": false,
                  "eventCursor": 3
                }
                """.utf8)
        )
        let client = FakeSessionServerClient(sessionId: sessionId)
        let transport = ServerSessionTransport(client: client, sessionId: sessionId)

        let page = transport.historyPage(from: rawPage)

        #expect(page.conversation.map(\.id) == [visibleId])
    }

    @Test("Server-backed loadHistory seeds materialized conversation and resumes from cursor")
    func serverBackedLoadHistorySeedsSnapshot() async {
        let sessionId = UUID()
        let userItemId = UUID()
        let assistantItemId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.detailCursor = 42
        client.detailConversation = [
            ServerConversationItem(
                id: userItemId.uuidString,
                role: .user,
                messageId: "user-1",
                text: "what changed?",
                createdAt: "2026-06-30T00:00:00.000Z",
                isGenerating: false
            ),
            ServerConversationItem(
                id: assistantItemId.uuidString,
                role: .assistant,
                messageId: "assistant-1",
                text: "Server-backed ",
                createdAt: "2026-06-30T00:00:01.000Z",
                isGenerating: false
            ),
            ServerConversationItem(
                id: UUID().uuidString,
                role: .assistant,
                messageId: "assistant-1",
                text: "history.",
                createdAt: "2026-06-30T00:00:02.000Z",
                isGenerating: false
            ),
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()
        await settleUntil { !client.eventSinceValues.isEmpty }

        #expect(client.eventSinceValues == [42])
        #expect(model.conversation.count == 2)
        guard case let .user(user) = model.conversation.first else {
            Issue.record("expected user")
            return
        }
        #expect(user.id == userItemId)
        #expect(user.text == "what changed?")
        guard case let .assistant(assistant) = model.conversation.last else {
            Issue.record("expected assistant")
            return
        }
        #expect(assistant.id == assistantItemId)
        #expect(assistant.turn.finalText == .text(id: "acp:assistant-1", markdown: "Server-backed history."))
    }

    @Test("Initial display paints transcript before prompt queue returns")
    func initialDisplayDoesNotWaitForPromptQueue() async {
        let sessionId = UUID()
        let itemId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [
                ServerTranscriptItem(
                    id: itemId.uuidString,
                    sessionId: sessionId.uuidString,
                    sequence: 1,
                    role: .user,
                    text: "paint me first",
                    createdAt: "2026-08-09T00:00:00.000Z",
                    updatedAt: "2026-08-09T00:00:00.000Z",
                    isGenerating: false,
                    hasDetails: false,
                    revision: 1
                )
            ],
            hasMore: false,
            eventCursor: 1
        )
        let queueItem = ServerPromptQueueItem(
            id: UUID().uuidString,
            sessionId: sessionId.uuidString,
            text: "queued",
            createdAt: "2026-08-09T00:00:01.000Z",
            updatedAt: "2026-08-09T00:00:01.000Z"
        )
        client.setPromptQueueResponse([queueItem])
        let (gate, releaseQueue) = AsyncStream.makeStream(of: Void.self)
        client.holdPromptQueue(until: gate)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistoryForInitialDisplay()
        await settleUntil { client.promptQueueRequestCount == 1 }

        #expect(model.conversation.map(\.id) == [itemId])
        #expect(model.queuedPrompts.isEmpty)

        releaseQueue.yield()
        releaseQueue.finish()
        await settleUntil { model.queuedPrompts == [queueItem] }
    }

    @Test("Paginated history restores the durable checklist and hides it once completed")
    func paginatedHistoryRestoresSessionPlan() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [],
            hasMore: false,
            eventCursor: 7,
            sessionPlan: Plan(entries: [
                PlanEntry(content: "Implement", priority: .medium, status: .inProgress)
            ])
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        let controller = SessionController(
            project: Project.fromFolder(URL(fileURLWithPath: "/tmp/paginated-plan-restore")),
            configCache: ConfigOptionCache(store: InMemoryStore())
        )
        controller.model = model

        await model.loadHistory()
        await settleUntil { client.sessionEventSinceValues == [7] }

        #expect(model.sessionPlan?.entries.first?.status == .inProgress)
        #expect(controller.visibleTodos?.entries.first?.content == "Implement")

        client.emit(
            ServerEventEnvelope(
                id: 8,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-08-28T00:00:00.000Z",
                payload: .object([
                    "sessionUpdate": .string("plan"),
                    "entries": .array([
                        .object([
                            "content": .string("Implement"),
                            "priority": .string("medium"),
                            "status": .string("completed"),
                        ])
                    ]),
                ])
            ))
        await settleUntil { model.sessionPlan?.entries.first?.status == .completed }

        // Completed state remains in the durable model but no longer occupies
        // the pinned checklist UI.
        #expect(model.sessionPlan?.entries.first?.status == .completed)
        #expect(controller.visibleTodos == nil)
    }

    @Test("Deferred prompt queue cannot overwrite a newer stream event")
    func deferredPromptQueuePreservesNewerStreamState() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [],
            hasMore: false,
            eventCursor: 0
        )
        let staleItem = ServerPromptQueueItem(
            id: UUID().uuidString,
            sessionId: sessionId.uuidString,
            text: "stale",
            createdAt: "2026-08-09T00:00:00.000Z",
            updatedAt: "2026-08-09T00:00:00.000Z"
        )
        let freshItem = ServerPromptQueueItem(
            id: UUID().uuidString,
            sessionId: sessionId.uuidString,
            text: "fresh",
            createdAt: "2026-08-09T00:00:01.000Z",
            updatedAt: "2026-08-09T00:00:01.000Z"
        )
        client.setPromptQueueResponse([staleItem])
        let (gate, releaseQueue) = AsyncStream.makeStream(of: Void.self)
        client.holdPromptQueue(until: gate)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistoryForInitialDisplay()
        await settleUntil { client.promptQueueRequestCount == 1 }
        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.queue.updated",
                subjectId: sessionId.uuidString,
                createdAt: "2026-08-09T00:00:01.000Z",
                payload: .object([
                    "queue": .array([
                        .object([
                            "id": .string(freshItem.id),
                            "sessionId": .string(freshItem.sessionId),
                            "text": .string(freshItem.text),
                            "createdAt": .string(freshItem.createdAt),
                            "updatedAt": .string(freshItem.updatedAt),
                        ])
                    ])
                ])
            ))
        await settleUntil { model.queuedPrompts == [freshItem] }

        releaseQueue.yield()
        releaseQueue.finish()
        await settleUntil { model.promptQueueLoadTask == nil }

        #expect(model.queuedPrompts == [freshItem])
    }

    @Test("Paginated history opens from the newest page and hydrates details on demand")
    func paginatedHistoryAndDeferredDetails() async {
        let sessionId = UUID()
        let olderId = UUID()
        let assistantId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.initialTranscriptPage = ServerTranscriptPage(
            items: [
                ServerTranscriptItem(
                    id: assistantId.uuidString,
                    sessionId: sessionId.uuidString,
                    sequence: 1,
                    role: .assistant,
                    text: "Summary answer",
                    createdAt: "2026-06-30T00:00:01.000Z",
                    updatedAt: "2026-06-30T00:00:02.000Z",
                    isGenerating: false,
                    hasDetails: true,
                    turnId: "turn-1",
                    startedAt: "2026-06-30T00:00:01.000Z",
                    endedAt: "2026-06-30T00:00:02.000Z",
                    stopReason: "end_turn",
                    stopDetail: nil,
                    planDocument: nil,
                    attachments: nil,
                    revision: 4
                )
            ],
            nextBefore: "1",
            hasMore: true,
            eventCursor: 12
        )
        client.olderTranscriptPage = ServerTranscriptPage(
            items: [
                ServerTranscriptItem(
                    id: olderId.uuidString,
                    sessionId: sessionId.uuidString,
                    sequence: 0,
                    role: .user,
                    text: "Older question",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    updatedAt: "2026-06-30T00:00:00.000Z",
                    isGenerating: false,
                    hasDetails: false,
                    turnId: nil,
                    startedAt: nil,
                    endedAt: nil,
                    stopReason: nil,
                    stopDetail: nil,
                    planDocument: nil,
                    attachments: nil,
                    revision: 1
                )
            ],
            nextBefore: nil,
            hasMore: false,
            eventCursor: 12
        )
        client.transcriptDetailsByItem[assistantId.uuidString] = ServerTranscriptItemDetails(
            itemId: assistantId.uuidString,
            revision: 4,
            events: [
                ServerEventEnvelope(
                    id: 10, serverId: "local", kind: "session.output",
                    subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:01.000Z",
                    payload: .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "messageId": .string("answer-1"),
                        "content": .object(["type": .string("text"), "text": .string("Summary answer")]),
                    ])
                ),
                ServerEventEnvelope(
                    id: 11, serverId: "local", kind: "session.output",
                    subjectId: sessionId.uuidString, createdAt: "2026-06-30T00:00:01.500Z",
                    payload: .object([
                        "sessionUpdate": .string("tool_call"),
                        "toolCallId": .string("tool-1"),
                        "title": .string("Read file"),
                    ])
                ),
            ]
        )
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()
        #expect(model.conversation.count == 1)
        #expect(model.hasOlderHistory)
        #expect(client.transcriptPageRequests.first?.before == nil)
        #expect(client.transcriptPageRequests.first?.limit == 8)
        await settleUntil { !client.sessionEventSinceValues.isEmpty }
        #expect(client.sessionEventSinceValues == [12])
        #expect(client.eventSinceValues.isEmpty)

        #expect(await model.loadOlderHistory() == 1)
        #expect(model.conversation.count == 2)
        #expect(model.conversation.first?.id == olderId)
        #expect(!model.hasOlderHistory)
        #expect(client.transcriptPageRequests.last?.before == "1")
        #expect(client.transcriptPageRequests.last?.limit == 16)
        #expect(await model.loadOlderHistory() == 0)

        #expect(await model.loadTranscriptDetails(itemId: assistantId.uuidString))
        guard case let .assistant(message) = model.conversation.last else {
            Issue.record("expected hydrated assistant")
            return
        }
        #expect(message.turn.finalText == .text(id: "acp:answer-1", markdown: "Summary answer"))
        let hasToolCall = message.turn.entries.contains(where: { entry in
            if case .tool = entry { return true }
            return false
        })
        #expect(hasToolCall)
        #expect(message.turn.deferredDetailItemId == nil)
        #expect(message.turn.hasHydratedWorkedDetails)
        #expect(client.transcriptDetailRequestCount == 1)

        // A replacement canonical page contains the compact deferred summary
        // again. The in-memory session restores its hydrated turn before that
        // page is published, so reopening needs neither a loading row nor a
        // second details request.
        await model.loadHistory()
        guard case let .assistant(restoredMessage) = model.conversation.last else {
            Issue.record("expected cached hydrated assistant")
            return
        }
        #expect(restoredMessage.turn.deferredDetailItemId == nil)
        #expect(restoredMessage.turn.hasHydratedWorkedDetails)
        #expect(client.transcriptDetailRequestCount == 1)
    }

    @Test("Replayed user events stamp attachments onto the optimistic echo and append remote ones")
    func userEventsCarryAttachments() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.echoOnPrompt = false
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        let refPayload: JSONValue = .array([
            .object([
                "fileId": .string("file-9"),
                "name": .string("shot.png"),
                "mimeType": .string("image/png"),
                "sizeBytes": .number(3),
                "kind": .string("image"),
            ])
        ])
        let expected = Attachment(
            fileId: "file-9", name: "shot.png", mimeType: "image/png", sizeBytes: 3, kind: .image
        )

        // The optimistic message has no attachments; the server echo does —
        // the echo's refs are stamped onto it instead of appending a dupe.
        await model.send("look at this")
        client.emit(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object([
                    "role": .string("user"),
                    "text": .string("look at this"),
                    "attachments": refPayload,
                ])
            ))
        await settleUntil { userMessages(model).first?.attachments.isEmpty == false }
        #expect(userMessages(model).count == 1)
        #expect(userMessages(model).first?.attachments == [expected])

        // A remote user message with attachments but no text still appends.
        client.emit(
            ServerEventEnvelope(
                id: 2,
                serverId: "local",
                kind: "session.output",
                subjectId: sessionId.uuidString,
                createdAt: "2026-06-30T00:00:01.000Z",
                payload: .object([
                    "role": .string("user"),
                    "text": .string(""),
                    "attachments": refPayload,
                ])
            ))
        await settleUntil { userMessages(model).count == 2 }
        #expect(userMessages(model).last?.text == "")
        #expect(userMessages(model).last?.attachments == [expected])
    }

    @Test("History snapshot conversation items carry attachments")
    func snapshotCarriesAttachments() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        client.detailConversation = [
            ServerConversationItem(
                id: UUID().uuidString,
                role: .user,
                messageId: nil,
                text: "with file",
                createdAt: "2026-06-30T00:00:00.000Z",
                isGenerating: false,
                attachments: [
                    ServerAttachmentRef(
                        fileId: "file-3", name: "doc.pdf", mimeType: "application/pdf",
                        sizeBytes: 9, kind: .file
                    )
                ]
            )
        ]
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        await model.loadHistory()

        #expect(
            userMessages(model).first?.attachments == [
                Attachment(fileId: "file-3", name: "doc.pdf", mimeType: "application/pdf", sizeBytes: 9, kind: .file)
            ])
    }

    @Test("Attachment refs decode when present and stay nil for older servers")
    func attachmentDecodeBackwardCompat() throws {
        let legacy = try JSONDecoder().decode(
            ServerConversationItem.self,
            from: Data(#"{"id":"a","role":"user","text":"hi","createdAt":"t","isGenerating":false}"#.utf8)
        )
        #expect(legacy.attachments == nil)

        let modern = try JSONDecoder().decode(
            ServerPromptQueueItem.self,
            from: Data(
                #"{"id":"q","sessionId":"s","text":"hi","createdAt":"t","updatedAt":"t","attachments":[{"fileId":"f","name":"n.png","mimeType":"image/png","sizeBytes":1,"kind":"image"}]}"#
                    .utf8
            )
        )
        #expect(modern.attachments?.first?.fileId == "f")
        #expect(modern.attachments?.first?.attachment.kind == .image)
    }
}
