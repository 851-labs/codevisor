import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Transient reconciliation retries preserve the stream and clear status when the snapshot succeeds")
  func transientReconciliationRetriesSilently() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      eventCursor: 0,
      text: "partial answer"
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      connectionRecoveryScheduler: scheduler.scheduler,
      connectionRecoveryStatusDelay: .seconds(1),
      connectionRecoveryFailureDelay: .seconds(2),
      connectionRecoveryRetryBaseDelay: .milliseconds(10),
      connectionRecoveryRetryMaximumDelay: .milliseconds(10)
    )
    defer { model.shutdown() }
    await model.send("keep working")
    await settleUntil {
      !client.eventSinceValues.isEmpty || !client.sessionEventSinceValues.isEmpty
    }
    let subscriptionsBeforeRecovery =
      client.eventSinceValues.count + client.sessionEventSinceValues.count
    client.failNextTranscriptPages(1)

    await model.reconcileIfInFlight()

    #expect(model.errorMessage == nil)
    #expect(model.connectionRecoveryMessage == nil)
    // A failed snapshot must immediately restore the cursor-backed stream
    // while the safe GET retries independently in the background.
    await settleUntil {
      client.eventSinceValues.count + client.sessionEventSinceValues.count
        > subscriptionsBeforeRecovery
    }
    #expect(
      client.eventSinceValues.count + client.sessionEventSinceValues.count
        > subscriptionsBeforeRecovery
    )

    await settleUntil { scheduler.pendingCount == 1 }
    #expect(scheduler.requestedIntervals == [.milliseconds(10)])
    scheduler.advance()
    await model.connectionRecoveryTask?.value
    #expect(client.transcriptPageRequests.count == 2)
    #expect(model.errorMessage == nil)
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.consumerTask != nil)
    model.apply(.synchronization(.caughtUp))
    #expect(model.connectionRecoveryMessage == nil)
  }

  @Test("Connection recovery delays status and manual retry until their thresholds")
  func connectionRecoveryPresentationThresholds() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId,
      isGenerating: true,
      stopReason: nil,
      text: "partial answer"
    )
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString,
      connectionRecoveryScheduler: scheduler.scheduler,
      connectionRecoveryStatusDelay: .milliseconds(20),
      connectionRecoveryFailureDelay: .milliseconds(60),
      connectionRecoveryRetryBaseDelay: .milliseconds(200),
      connectionRecoveryRetryMaximumDelay: .milliseconds(200)
    )
    defer { model.shutdown() }
    await model.send("keep working")
    client.failNextTranscriptPages(100)

    await model.reconcileFromServer()

    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.errorMessage == nil)
    await settleUntil { scheduler.pendingCount == 1 }
    #expect(scheduler.requestedIntervals == [.milliseconds(20)])
    scheduler.advance()
    await settleUntil { model.connectionRecoveryMessage == "Reconnecting…" }
    #expect(model.errorMessage == nil)
    await settleUntil { scheduler.pendingCount == 1 }
    #expect(scheduler.requestedIntervals == [.milliseconds(20), .milliseconds(40)])
    scheduler.advance()
    await settleUntil { model.errorMessage != nil }
    #expect(model.connectionRecoveryMessage == nil)

    client.clearTranscriptPageFailures()
    await model.retrySessionFailure()
    #expect(model.connectionRecoveryTask == nil)
    #expect(model.connectionRecoveryMessage == nil)
    model.apply(.synchronization(.caughtUp))
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.errorMessage == nil)
    #expect(model.isSending)
  }
}

extension SessionModelTests {
  @Test("Recovery keeps cached details and older pages visible until the replacement is complete")
  func recoveryInstallsSnapshotAtomically() async throws {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    var page = cancellationTranscriptPage(
      sessionId: sessionId, isGenerating: true,
      stopReason: nil, eventCursor: 2, text: "Cached answer")
    let assistantId = try #require(UUID(uuidString: page.items[0].id))
    client.initialTranscriptPage = page
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    await model.loadHistory()
    let older = ConversationItem.user(UserMessage(text: "Already loaded older page"))
    guard case let .assistant(cachedMessage)? = model.conversation.last else {
      Issue.record("Expected cached assistant"); return
    }
    let cachedTurn = cachedMessage.turn
    model.setConversation([older, .assistant(AssistantMessage(id: assistantId, turn: cachedTurn))])
    model.hasOlderHistory = true
    model.olderHistoryCursor = "older-page"
    let cached = model.conversation

    page.eventCursor = 3
    page.items[0].revision = 3
    page.items[0].hasDetails = true
    page.items[0].text = "Recovered answer"
    page.items[0].isGenerating = false
    page.items[0].stopReason = "end_turn"
    client.initialTranscriptPage = page
    client.transcriptDetailsByItem[page.items[0].id] = ServerTranscriptItemDetails(
      itemId: page.items[0].id, revision: 3,
      events: [
        ServerEventEnvelope(
          id: 3, subjectRevision: 3, serverId: "local", kind: "session.output",
          subjectId: sessionId.uuidString, createdAt: "2026-09-10T00:00:00.000Z",
          payload: .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("recovered-tool"), "title": .string("Read state"),
          ]))
      ])
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    client.holdTranscriptDetails(until: gate)
    model.apply(.synchronization(.reconnecting))
    let recovery = Task { await model.reconcileIfInFlight() }
    await settleUntil { client.transcriptDetailRequestCount == 1 }
    #expect(model.conversation == cached)
    #expect(model.serverEventCursor == 2)
    #expect(model.connectionRecoveryMessage == "Reconnecting…")
    // A foreground and a sidebar repair racing must share the first attempt.
    await model.reconcileFromServer()
    #expect(client.transcriptPageRequests.count == 2)
    release.yield()
    release.finish()
    await recovery.value
    #expect(model.serverEventCursor == 3)
    #expect(model.conversation.first == older)
    #expect(model.hasOlderHistory)
    #expect(model.olderHistoryCursor == "older-page")
    #expect(!model.isSending)
    guard case let .assistant(recovered)? = model.conversation.last else {
      Issue.record("Expected recovered assistant"); return
    }
    #expect(recovered.turn.allToolCalls.map(\.toolCallId) == ["recovered-tool"])
    #expect(model.connectionRecoveryMessage == nil)
    model.apply(.synchronization(.caughtUp))
    #expect(model.connectionRecoveryMessage == nil)
  }
}

extension SessionModelTests {
  @Test("Missing active details retry without applying live events to an incomplete baseline")
  func missingActiveDetailsKeepRecoveryGate() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    var page = cancellationTranscriptPage(
      sessionId: sessionId, isGenerating: true,
      stopReason: nil, eventCursor: 2, text: "Cached baseline")
    page.items[0].hasDetails = true
    client.initialTranscriptPage = page
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString, connectionRecoveryScheduler: scheduler.scheduler,
      connectionRecoveryRetryBaseDelay: .milliseconds(10), connectionRecoveryRetryMaximumDelay: .milliseconds(10))
    defer { model.shutdown() }
    await model.loadHistoryForInitialDisplay()
    await settleUntil { scheduler.pendingCount == 1 }
    #expect(client.transcriptDetailRequestCount == 2)
    #expect(model.isActiveTranscriptHydrationPending)
    #expect(model.serverEventCursor == 2)
    #expect(model.connectionRecoveryMessage == "Reconnecting…")
    #expect(model.usesPaginatedHistory)
    client.transcriptDetailsByItem[page.items[0].id] = ServerTranscriptItemDetails(
      itemId: page.items[0].id, revision: 2,
      events: [
        toolCallEnvelope(
          id: 2,
          sessionId: sessionId, toolCallId: "historical-tool", status: "completed")
      ])
    scheduler.advance()
    await model.connectionRecoveryTask?.value
    #expect(!model.isActiveTranscriptHydrationPending)
    guard case let .assistant(message) = model.activeItem else {
      Issue.record("Expected recovered active turn"); return
    }
    #expect(message.turn.allToolCalls.map(\.toolCallId) == ["historical-tool"])
  }
}

extension SessionModelTests {
  @Test("Sidebar completion repairs a missed finish but cannot erase an unacknowledged prompt")
  func sidebarCompletionRespectsPendingPrompt() async {
    let sessionId = UUID()
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/recovery-project"))
    let controller = SessionController(project: project, configCache: ConfigOptionCache(store: InMemoryStore()))
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.echoOnPrompt = false
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId, isGenerating: false,
      stopReason: "end_turn", eventCursor: 3, text: "Completed remotely")
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    controller.model = model
    await model.send("New prompt")
    let summary = ChatSession(id: sessionId, projectId: project.id, sidebarState: .idle)
    await controller.reconcileServerSummary(summary, revision: 3)
    #expect(model.isSending)
    #expect(client.transcriptPageRequests.isEmpty)
    model.pendingOptimisticUserMessageIDs.removeAll()
    model.serverEventCursor = 3
    await controller.reconcileServerSummary(summary, revision: 3)
    #expect(client.transcriptPageRequests.isEmpty)
    model.serverEventCursor = 2
    await controller.reconcileServerSummary(summary, revision: 3)
    #expect(client.transcriptPageRequests.count == 1)
    #expect(!model.isSending)
    #expect(model.serverEventCursor == 3)
    #expect(model.connectionRecoveryMessage == nil)
  }
}
