import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  @Test("Locating a tool call hydrates summarized turns until it finds the call")
  func toolCallLocationHydratesSummarizedTurns() async {
    let sessionId = UUID()
    let client = FakeSessionServerClient(sessionId: sessionId)
    let olderId = UUID()
    let newerId = UUID()
    client.initialTranscriptPage = ServerTranscriptPage(
      items: [
        transcriptStateItem(id: olderId, sessionId: sessionId, hasDetails: true),
        transcriptStateItem(id: newerId, sessionId: sessionId, hasDetails: true),
      ], hasMore: false, eventCursor: 5)
    client.transcriptDetailsByItem[olderId.uuidString] = toolCallDetails(itemId: olderId, toolCallId: "bash-1")
    client.transcriptDetailsByItem[newerId.uuidString] = toolCallDetails(itemId: newerId, toolCallId: "read-1")

    await model(client, sessionId: sessionId) { model in
      await model.loadHistoryForInitialDisplay()

      let location = await model.workedItemLocation(ofToolCall: "bash-1")

      #expect(location?.reference.messageID == model.conversation.first?.id)
      #expect(location?.reference.itemID == "wgroup:bash-1")
      #expect(await model.workedItemLocation(ofToolCall: "missing") == nil)
    }
  }

  private func toolCallDetails(itemId: UUID, toolCallId: String) -> ServerTranscriptItemDetails {
    ServerTranscriptItemDetails(
      itemId: itemId.uuidString, revision: 1, eventCursor: 5,
      entries: [
        .init(
          key: "tool:\(toolCallId)", position: 1, revision: 1,
          payload: .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string(toolCallId),
            "title": .string("Bash"), "kind": .string("execute"), "status": .string("completed"),
          ]))
      ])
  }
}
