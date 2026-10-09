import Foundation
import Testing

@testable import CodevisorClient

@Suite("Composer skills wire contract")
struct ServerComposerSkillTests {
  @Test("Decodes the server's list; a missing builtin flag or description is tolerated")
  func decoding() throws {
    let body = Data(
      """
      {"skills":[
        {"name":"browser-use","description":"Browse the web with Codevisor's browser","builtin":true},
        {"name":"haiku-reply","description":"Answer in a single haiku","builtin":false},
        {"name":"deploy"}
      ]}
      """.utf8)

    let list = try JSONDecoder().decode(ServerComposerSkillsList.self, from: body)

    #expect(
      list.skills == [
        ServerComposerSkill(name: "browser-use", description: "Browse the web with Codevisor's browser", builtin: true),
        ServerComposerSkill(name: "haiku-reply", description: "Answer in a single haiku", builtin: false),
        ServerComposerSkill(name: "deploy", description: nil, builtin: false),
      ])
  }

  @Test("Asks for the project, adding the session once the chat exists on the server")
  func requestPath() throws {
    let projectId = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    let sessionId = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

    #expect(
      try CodevisorServerClient.composerSkillsPath(projectId: projectId, sessionId: nil)
        == "/v1/composer-skills?projectId=11111111-2222-3333-4444-555555555555")
    #expect(
      try CodevisorServerClient.composerSkillsPath(projectId: projectId, sessionId: sessionId)
        == "/v1/composer-skills?projectId=11111111-2222-3333-4444-555555555555"
        + "&sessionId=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    // A "No project" draft asks for the machine's defaults.
    #expect(
      try CodevisorServerClient.composerSkillsPath(projectId: nil, sessionId: nil)
        == "/v1/composer-skills")
  }
}
