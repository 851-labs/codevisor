import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Recovery preserves already loaded older history")
  func recoveryPreservesLoadedOlderHistory() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId, isGenerating: true, stopReason: nil,
      eventCursor: 2, text: "Current turn")
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    await model.loadHistoryForInitialDisplay()
    let old = ConversationItem.user(UserMessage(text: "Earlier loaded message"))
    model.setConversation([old] + model.conversation)
    client.initialTranscriptPage?.eventCursor = 3
    _ = await model.loadHistoryForConnectionRecovery()
    #expect(model.conversation.contains(old))
  }

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
    await model.connectionRecovery.task?.value
    #expect(client.transcriptPageRequests.count == 2)
    #expect(model.errorMessage == nil)
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.consumerTask != nil)
    model.apply(.synchronization(.caughtUp))
    #expect(model.connectionRecoveryMessage == nil)
  }

  @Test("Connection recovery says it is reconnecting after its threshold, and keeps retrying without ever giving up")
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
    for _ in 0..<3 {
      await settleUntil { scheduler.pendingCount == 1 }
      scheduler.advance()
    }
    await settleUntil { scheduler.pendingCount == 1 }
    #expect(model.errorMessage == nil)
    #expect(model.connectionRecoveryMessage == "Reconnecting…")

    let attempts = client.transcriptPageRequests.count
    client.clearTranscriptPageFailures()
    scheduler.advance()
    await model.connectionRecovery.task?.value
    #expect(client.transcriptPageRequests.count > attempts)
    #expect(model.connectionRecovery.task == nil)
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.errorMessage == nil)
    #expect(model.isSending)
  }

}

extension SessionModelTests {
  @Test("Recovery installs the current snapshot without waiting for deferred details")
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
    await model.loadHistoryForInitialDisplay()
    let older = ConversationItem.user(UserMessage(text: "Already loaded older page"))
    guard case let .assistant(cachedMessage)? = model.conversation.last else {
      Issue.record("Expected cached assistant"); return
    }
    let cachedTurn = cachedMessage.turn
    model.setConversation([older, .assistant(AssistantMessage(id: assistantId, turn: cachedTurn))])
    model.historyPaging.hasOlderPages = true
    model.historyPaging.olderPageCursor = "older-page"

    page.eventCursor = 3
    page.items[0].revision = 3
    page.items[0].hasDetails = true
    page.items[0].text = "Recovered answer"
    page.items[0].isGenerating = false
    page.items[0].stopReason = "end_turn"
    client.initialTranscriptPage = page
    model.apply(.synchronization(.reconnecting))
    await model.reconcileIfInFlight()
    #expect(client.transcriptDetailRequestCount == 0)
    #expect(model.serverEventCursor == 3)
    #expect(model.conversation.first == older)
    #expect(model.hasOlderHistory)
    #expect(model.historyPaging.olderPageCursor == "older-page")
    #expect(!model.isSending)
    guard case let .assistant(recovered)? = model.conversation.last else {
      Issue.record("Expected recovered assistant"); return
    }
    #expect(recovered.turn.hasDeferredWorkedDetails)
    #expect(model.connectionRecoveryMessage == nil)
    model.apply(.synchronization(.caughtUp))
    #expect(model.connectionRecoveryMessage == nil)
  }
}

extension SessionModelTests {
  @Test("Recovery refreshes the work of a turn the user already opened before showing it")
  func recoveryRefreshesOpenedWork() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    var page = cancellationTranscriptPage(
      sessionId: sessionId, isGenerating: false,
      stopReason: "end_turn", eventCursor: 2, text: "Finished answer")
    page.items[0].hasDetails = true
    let itemId = page.items[0].id
    func details(revision: Int, toolCallId: String) -> ServerTranscriptItemDetails {
      ServerTranscriptItemDetails(
        itemId: itemId, revision: revision, eventCursor: revision,
        entries: [
          ServerTranscriptEntry(
            key: "tool:\(toolCallId)", position: 2, revision: revision,
            payload: toolCallEnvelope(id: revision, sessionId: sessionId, toolCallId: toolCallId, status: "completed")
              .payload)
        ])
    }
    client.initialTranscriptPage = page
    client.transcriptDetailsByItem[itemId] = details(revision: 2, toolCallId: "first-edit")
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    await model.loadHistoryForInitialDisplay()
    #expect(await model.loadTranscriptDetails(itemId: itemId))

    page.eventCursor = 3
    page.items[0].revision = 3
    client.initialTranscriptPage = page
    client.transcriptDetailsByItem[itemId] = details(revision: 3, toolCallId: "second-edit")
    await model.reconcileFromServer()

    #expect(client.transcriptDetailRequestCount == 2)
    #expect(model.serverEventCursor == 3)
    guard case let .assistant(message)? = model.conversation.last else {
      Issue.record("Expected recovered assistant"); return
    }
    #expect(message.turn.allToolCalls.map(\.toolCallId) == ["second-edit"])
    #expect(message.turn.hasHydratedWorkedDetails)
  }

  @Test("A missing detail page does not block live synchronization and can be retried")
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
    #expect(client.transcriptDetailRequestCount == 0)
    #expect(model.serverEventCursor == 2)
    #expect(await model.loadTranscriptDetails(itemId: page.items[0].id) == false)
    client.transcriptDetailsByItem[page.items[0].id] = ServerTranscriptItemDetails(
      itemId: page.items[0].id, revision: 2, eventCursor: 2,
      entries: [
        ServerTranscriptEntry(
          key: "tool:historical-tool", position: 2, revision: 2,
          payload: toolCallEnvelope(id: 2, sessionId: sessionId, toolCallId: "historical-tool", status: "completed")
            .payload)
      ])
    #expect(await model.loadTranscriptDetails(itemId: page.items[0].id))
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

extension SessionModelTests {
  private func recoveringModel(
    _ client: FakeSessionServerClient,
    sessionId: UUID,
    scheduler: ManualSessionConnectionRecoveryScheduler
  ) -> SessionModel {
    SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString, connectionRecoveryScheduler: scheduler.scheduler,
      connectionRecoveryRetryBaseDelay: .milliseconds(10), connectionRecoveryRetryMaximumDelay: .milliseconds(10))
  }

  @Test("A permanent reconciliation failure shows its error without retrying, until a later recovery clears it")
  func permanentReconciliationFailureSurfaces() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let model = recoveringModel(client, sessionId: sessionId, scheduler: scheduler)
    defer { model.shutdown() }
    client.failNextTranscriptPages(1, with: CodevisorServerClientError.httpStatus(404, "missing"))

    await model.reconcileFromServer()

    let firstError = model.errorMessage
    #expect(firstError != nil)
    #expect(model.connectionRecovery.task == nil)
    #expect(model.connectionRecoveryMessage == nil)
    #expect(scheduler.requestedIntervals.isEmpty)

    client.failNextTranscriptPages(1, with: CodevisorServerClientError.invalidResponse)
    await model.reconcileFromServer()

    #expect(model.errorMessage != nil)
    #expect(model.errorMessage != firstError)

    await model.reconcileFromServer()

    #expect(model.errorMessage == nil)
    #expect(client.transcriptPageRequests.count == 3)
    #expect(scheduler.requestedIntervals.isEmpty)
  }

  @Test("A permanent reconciliation failure leaves an unrelated error in place")
  func permanentReconciliationFailureKeepsUnrelatedError() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let model = recoveringModel(client, sessionId: sessionId, scheduler: scheduler)
    defer { model.shutdown() }
    model.errorMessage = "Unrelated failure"
    client.failNextTranscriptPages(1, with: CodevisorServerClientError.httpStatus(404, "missing"))

    await model.reconcileFromServer()
    #expect(model.errorMessage == "Unrelated failure")

    await model.reconcileFromServer()
    #expect(model.errorMessage == "Unrelated failure")
  }

  @Test("Retry cancels a running recovery loop, then reconciles once more")
  func retrySessionFailureReplacesRecoveryLoop() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let model = recoveringModel(client, sessionId: sessionId, scheduler: scheduler)
    defer { model.shutdown() }
    client.failNextTranscriptPages(100)
    await model.reconcileFromServer()
    await settleUntil { scheduler.pendingCount == 1 }
    let requests = client.transcriptPageRequests.count
    client.clearTranscriptPageFailures()

    await model.retrySessionFailure()

    #expect(scheduler.pendingCount == 0)
    #expect(model.connectionRecovery.task == nil)
    #expect(client.transcriptPageRequests.count == requests + 1)
    #expect(model.errorMessage == nil)
    #expect(model.connectionRecoveryMessage == nil)
  }

  @Test("Reconciling while a recovery is already running leaves that recovery alone")
  func reconcileDuringRecoveryIsIgnored() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let model = recoveringModel(client, sessionId: sessionId, scheduler: scheduler)
    defer { model.shutdown() }
    client.failNextTranscriptPages(100)
    await model.reconcileFromServer()
    await settleUntil { scheduler.pendingCount == 1 }
    let recovery = model.connectionRecovery.task
    let requests = client.transcriptPageRequests.count

    await model.reconcileFromServer()

    #expect(recovery != nil)
    #expect(model.connectionRecovery.task == recovery)
    #expect(client.transcriptPageRequests.count == requests)
    #expect(scheduler.pendingCount == 1)
  }

  @Test("A stopped recovery attempt that finishes late doesn't clear its replacement")
  func staleRecoveryAttemptKeepsReplacement() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let model = recoveringModel(client, sessionId: sessionId, scheduler: scheduler)
    defer { model.shutdown() }
    client.transcriptPageFaults.holdNext()
    let stale = Task { await model.reconcileFromServer() }
    await client.transcriptPageFaults.held.wait()
    model.connectionRecovery.stop()
    client.failNextTranscriptPages(100)
    await model.reconcileFromServer()
    await settleUntil { scheduler.pendingCount == 1 }
    let replacement = model.connectionRecovery.task

    client.transcriptPageFaults.release.signal()
    await stale.value

    #expect(replacement != nil)
    #expect(model.connectionRecovery.task == replacement)
    #expect(scheduler.pendingCount == 1)
  }

  @Test("A recovery loop keeps its session model alive until it settles")
  func recoveryLoopRetainsModel() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    weak var weakModel: SessionModel?
    var recovery: Task<Void, Never>?
    do {
      let model = recoveringModel(client, sessionId: sessionId, scheduler: scheduler)
      weakModel = model
      client.failNextTranscriptPages(1)
      await model.reconcileFromServer()
      await settleUntil { scheduler.pendingCount == 1 }
      recovery = model.connectionRecovery.task
    }
    #expect(weakModel != nil)

    scheduler.advance()
    await recovery?.value
    client.finishEvents()

    #expect(weakModel == nil)
  }
}
