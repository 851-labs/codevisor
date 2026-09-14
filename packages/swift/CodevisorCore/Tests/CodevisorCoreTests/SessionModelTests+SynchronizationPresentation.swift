import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Foreground checks stay quiet without server heartbeats", arguments: [false, true])
  func foregroundSynchronizationStaysQuiet(isGenerating: Bool) async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId, isGenerating: isGenerating,
      stopReason: isGenerating ? nil : "end_turn", eventCursor: 3, text: "Visible reply")
    let transport = ServerSessionTransport(client: client, sessionId: sessionId)
    let model = SessionModel(serverTransport: transport, sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    await model.loadHistory()
    model.viewDidAppear()
    let cached = model.conversation

    // The fake deliberately sends no checkpoints, matching the quiet period
    // before an older server's first 25-second heartbeat.
    await model.reconcileIfInFlight()
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.conversation == cached)
    #expect(model.isSending == isGenerating)
    let requests = client.transcriptPageRequests.count
    await model.reconcileIfStalled()
    #expect(client.transcriptPageRequests.count == requests)
    await model.reconcileIfInFlight()
    #expect(model.connectionRecoveryMessage == nil)
    await model.adoptTransport(transport)
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.conversation == cached)
  }

  @Test("Resumed traffic clears disconnection without claiming checkpoint completion")
  func resumedTrafficClearsRecovery() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString)
    defer { model.shutdown() }
    model.apply(.synchronization(.reconnecting))
    #expect(model.connectionRecoveryMessage == "Reconnecting…")
    let revision = model.transcriptProjectionRevision

    model.apply(.synchronization(.catchingUp))
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.streamSynchronization == .catchingUp)
    #expect(model.transcriptProjectionRevision > revision)
    model.apply(.synchronization(.caughtUp))
    #expect(model.connectionRecoveryMessage == nil)

    // A subsequent real failure must still surface the single recovery row.
    model.apply(.synchronization(.reconnecting))
    #expect(model.connectionRecoveryMessage == "Reconnecting…")
  }

  @Test("Live output retires snapshot retries before an older server's heartbeat")
  func liveOutputRetiresSnapshotRetry() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    client.initialTranscriptPage = cancellationTranscriptPage(
      sessionId: sessionId, isGenerating: true,
      stopReason: nil, eventCursor: 3, text: "Visible reply")
    let scheduler = ManualSessionConnectionRecoveryScheduler()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
      sessionId: sessionId.uuidString, connectionRecoveryScheduler: scheduler.scheduler)
    defer { model.shutdown() }
    await model.loadHistory()
    client.failNextTranscriptPages(100)
    await model.reconcileFromServer()
    await settleUntil { scheduler.pendingCount == 1 }
    let recovery = model.connectionRecoveryTask
    let requests = client.transcriptPageRequests.count

    model.apply(.synchronization(.catchingUp))
    model.apply(.update(.agentMessageChunk(.text(" more live text"))))
    await recovery?.value
    await settleUntil { scheduler.pendingCount == 0 }
    #expect(model.connectionRecoveryTask == nil)
    #expect(model.connectionRecoveryMessage == nil)
    #expect(model.errorMessage == nil)
    #expect(model.streamSynchronization == .catchingUp)
    #expect(client.transcriptPageRequests.count == requests)
    #expect(model.isSending)
  }
}
