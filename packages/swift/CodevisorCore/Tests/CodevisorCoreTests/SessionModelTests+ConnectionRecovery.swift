import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    @Test("Transient reconciliation failures retry silently and preserve the event consumer")
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
        await settleUntil { model.connectionRecoveryTask == nil }
        #expect(client.transcriptPageRequests.count == 2)
        #expect(model.errorMessage == nil)
        #expect(model.connectionRecoveryMessage == nil)
        #expect(model.consumerTask != nil)
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
        await model.send("keep working")
        client.failNextTranscriptPages(100)

        await model.reconcileIfInFlight()

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
        #expect(model.errorMessage == nil)
        #expect(model.isSending)
    }
}
