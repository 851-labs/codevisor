import ACPKit
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorClient

@Suite("Plugin setup cards")
struct ServerPluginSetupRequestTests {
  @Test("A plugin_setup update carries its plugin and is a card, not a question")
  func decodesSetupUpdate() throws {
    let json =
      #"{"sessionUpdate":"plugin_setup","setupId":"plugin-setup:1","state":"pending","request":\#(Self.setupJSON)}"#

    let update = try JSONDecoder().decode(SessionUpdate.self, from: Data(json.utf8))

    guard case let .pluginSetup(shown) = update else {
      Issue.record("expected a plugin setup update")
      return
    }
    let setup = try #require(ServerPluginSetupRequest.decoded(from: shown.request))
    #expect(shown.setupId == "plugin-setup:1" && shown.state == .pending)
    #expect(setup.name == "Gmail")
    #expect(setup.catalogId == "gmail")
    #expect(setup.auth == .oauth2)
    #expect(setup.machine.name == "Studio")
    #expect(setup.capabilities.events.map(\.name) == ["message.received"])
  }

  @Test("A transcript item lists its setup cards with the state the server gave them")
  func historyCards() throws {
    let json =
      #"[{"id":"plugin-setup:1","state":"connected","request":\#(Self.setupJSON)},{"id":"plugin-setup:2","state":"later","request":{}}]"#

    let cards = try JSONDecoder().decode([ServerTranscriptPluginSetup].self, from: Data(json.utf8))
      .compactMap(\.transcriptInteraction)

    #expect(cards.map(\.id) == ["plugin-setup:1"])
    guard case let .pluginSetup(card)? = cards.first?.content else {
      Issue.record("expected a plugin setup card")
      return
    }
    #expect(card.state == .connected)
  }

  @Test("A setup question from before cards stays only when it ended connected")
  func earlierSetupQuestions() throws {
    let connected = try Self.earlierQuestion(answer: #","answer":{"outcome":"autoResolved"}"#)
    let declined = try Self.earlierQuestion(answer: #","answer":{"outcome":"cancelled"}"#)
    let abandoned = try Self.earlierQuestion(answer: "")

    guard case let .pluginSetup(card)? = connected.transcriptInteraction?.content else {
      Issue.record("expected the connected card")
      return
    }
    #expect(card.state == .connected)
    #expect(declined.transcriptInteraction == nil)
    #expect(abandoned.transcriptInteraction == nil)
  }

  private static func earlierQuestion(answer: String) throws -> ServerTranscriptInteraction {
    let json = """
      {"id":"plugin-setup:0","kind":"question","payload":{"questions":[{"id":"plugin_setup","header":"Gmail",\
      "question":"Read your inbox","options":[{"label":"Set Up"},{"label":"Not Now"}],"allowsOther":false,\
      "presentation":"pluginSetup","pluginSetup":\(setupJSON)}]}\(answer)}
      """
    return try JSONDecoder().decode(ServerTranscriptInteraction.self, from: Data(json.utf8))
  }

  private static let setupJSON = """
    {"plugin":"gmail","catalogId":"gmail","name":"Gmail","publisher":"Codevisor","reason":"Read your inbox",\
    "auth":"oauth2","capabilities":{"tools":[],"events":[{"name":"message.received"}],"skills":[],"panes":[],\
    "ingress":[]},"machine":{"id":"m-1","name":"Studio"}}
    """
}
