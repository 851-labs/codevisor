import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

extension SessionModelTests {
  @Test("A plugin setup card reads Connected after a reconnect reloads the chat with the card in its server item")
  func pluginSetupCardConnectsAcrossReload() throws {
    let sessionId = UUID()
    let model = SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionId), sessionId: sessionId),
      sessionId: sessionId.uuidString
    )
    let replyItem = UUID()
    let cardItem = UUID()
    let request = JSONValue.object(["plugin": .string("dev.codevisor/test-events")])
    func setup(_ state: PluginSetupUpdate.State) -> SessionUpdate {
      .pluginSetup(PluginSetupUpdate(setupId: "setup-1", state: state, request: request))
    }
    func reply(withCard card: Bool) -> ConversationItem {
      var turn = AssistantTurn(entries: [.text(id: "t", markdown: "Connect it from the card.")])
      if card { turn.interactions = TranscriptInteractions([Self.card(state: .pending, request: request)]) }
      return .assistant(AssistantMessage(id: card ? cardItem : replyItem, turn: turn))
    }
    model.setConversation([reply(withCard: false)])

    model.apply(.update(setup(.pending)))
    model.setConversation([reply(withCard: false), reply(withCard: true)])
    model.apply(.update(setup(.connected)))

    #expect(Self.setupStates(in: model.conversation, id: "setup-1") == [.connected])
  }

  private static func card(state: PluginSetupUpdate.State, request: JSONValue) -> TranscriptInteraction {
    TranscriptInteraction(
      id: "setup-1", content: .pluginSetup(TranscriptPluginSetup(id: "setup-1", state: state, request: request)))
  }

  private static func setupStates(in conversation: [ConversationItem], id: String) -> [PluginSetupUpdate.State] {
    conversation.flatMap { item -> [PluginSetupUpdate.State] in
      guard case let .assistant(message) = item else { return [] }
      return message.turn.interactions.items.compactMap { interaction in
        guard interaction.id == id, case let .pluginSetup(setup) = interaction.content else { return nil }
        return setup.state
      }
    }
  }
}
