import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
    @Test("Queued message updates trim input and report transport failures")
    func queuedMessageUpdateResult() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        #expect(!(await model.updateQueuedPrompt(id: "queue-1", text: "   ")))
        #expect(client.queueUpdates.isEmpty)

        #expect(await model.updateQueuedPrompt(id: "queue-1", text: "  revised message  "))
        #expect(client.queueUpdates.count == 1)
        #expect(client.queueUpdates.first?.id == "queue-1")
        #expect(client.queueUpdates.first?.text == "revised message")

        client.failNextQueueMutation()
        #expect(!(await model.updateQueuedPrompt(id: "queue-1", text: "fails")))
        #expect(model.errorMessage != nil)
    }

    @Test("Queued message deletion reports success and transport failures")
    func queuedMessageDeleteResult() async {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )

        #expect(await model.deleteQueuedPrompt(id: "queue-1"))
        #expect(client.queueDeletes == ["queue-1"])

        client.failNextQueueMutation()
        #expect(!(await model.deleteQueuedPrompt(id: "queue-2")))
        #expect(model.errorMessage != nil)
    }
}
