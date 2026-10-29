import Foundation
import Testing
@testable import CodevisorCore

@Suite("Skills wire models")
struct SkillsWireModelTests {
  private let decoder = JSONDecoder()

  @Test("decodes the skill store list with optional fields absent")
  func decodesSkillsList() throws {
    let json = """
      {
        "dir": "/home/u/.codevisor/skills",
        "skills": [
          {
            "name": "Deploy",
            "directoryName": "deploy",
            "description": "Deploy checklist",
            "path": "/home/u/.codevisor/skills/deploy"
          },
          {
            "name": "broken",
            "directoryName": "broken",
            "path": "/home/u/.codevisor/skills/broken",
            "invalid": true
          }
        ]
      }
      """
    let list = try decoder.decode(ServerSkillsList.self, from: Data(json.utf8))
    #expect(list.dir == "/home/u/.codevisor/skills")
    #expect(list.skills.map(\.id) == ["deploy", "broken"])
    #expect(list.skills[0].invalid == nil)
    #expect(list.skills[1].description == nil)
    #expect(list.skills[1].invalid == true)
  }

}
