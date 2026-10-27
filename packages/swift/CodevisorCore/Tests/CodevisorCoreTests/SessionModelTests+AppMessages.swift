import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  @Test("An app's message never takes over the user's pending bubble with the same text")
  func appMessageStaysSeparate() async {
    let sessionID = UUID()
    let client = FakeSessionServerClient(sessionId: sessionID)
    client.echoOnPrompt = false
    let model = SessionModel(
      serverTransport: ServerSessionTransport(client: client, sessionId: sessionID), sessionId: sessionID.uuidString)
    defer { model.shutdown() }
    let typed = UserMessage(text: "Tour it")
    await model.send(typed)
    let attribution = UserMessageAttribution.app(viewId: "view-1", plugin: "Zillow")

    model.apply(.userMessage(id: UUID().uuidString, text: "Tour it", attachments: [], attribution: attribution))

    let users = model.conversation.compactMap { item -> UserMessage? in
      guard case let .user(user) = item else { return nil }
      return user
    }
    #expect(users.map(\.attribution) == [nil, attribution])
    #expect(users.first?.id == typed.id)
    #expect(model.pendingOptimisticUserMessageIDs.contains(typed.id))
  }
}
