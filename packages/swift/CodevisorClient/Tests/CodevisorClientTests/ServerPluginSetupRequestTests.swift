import ACPKit
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorClient

@Suite("Plugin setup questions")
struct ServerPluginSetupRequestTests {
  @Test("A pluginSetup question carries its plugin and stays an in-transcript question")
  func decodesSetupRequest() throws {
    let questions = try Self.questions(presentation: "pluginSetup", payload: Self.setupJSON)

    let setup = try #require(ServerPluginSetupRequest.decoded(from: questions))

    #expect(setup.name == "Gmail")
    #expect(setup.catalogId == "gmail")
    #expect(setup.auth == .oauth2)
    #expect(setup.machine.name == "Studio")
    #expect(setup.capabilities.events.map(\.name) == ["message.received"])
    #expect(TranscriptSetupRequest.kind(of: questions) == nil)
    #expect(TranscriptQuestion.asksInTranscript(questions))
  }

  @Test("A question with a presentation this client doesn't know still renders as a plain question")
  func unknownPresentation() throws {
    let questions = try Self.questions(presentation: "somethingNew", payload: nil)

    #expect(questions.first?.presentation == nil)
    #expect(ServerPluginSetupRequest.decoded(from: questions) == nil)
    #expect(TranscriptQuestion.asksInTranscript(questions))
  }

  private static func questions(presentation: String, payload: String?) throws -> [QuestionSpec] {
    let setup = payload.map { #","pluginSetup":"# + $0 } ?? ""
    let json = """
      [{"id":"plugin_setup","header":"Gmail","question":"Read your inbox","options":[{"label":"Set Up"},\
      {"label":"Not Now"}],"allowsOther":false,"presentation":"\(presentation)"\(setup)}]
      """
    return try JSONDecoder().decode([QuestionSpec].self, from: Data(json.utf8))
  }

  private static let setupJSON = """
    {"plugin":"gmail","catalogId":"gmail","name":"Gmail","publisher":"Codevisor","reason":"Read your inbox",\
    "auth":"oauth2","capabilities":{"tools":[],"events":[{"name":"message.received"}],"skills":[],"panes":[],\
    "ingress":[]},"machine":{"id":"m-1","name":"Studio"}}
    """
}
