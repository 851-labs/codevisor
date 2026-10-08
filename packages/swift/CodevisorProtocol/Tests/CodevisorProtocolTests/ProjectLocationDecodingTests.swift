import CodevisorProtocol
import Foundation
import Testing

private let modernLocationCases: [(String, [ProjectLocation])] = [
  (
    """
    {"id":"11111111-1111-4111-8111-111111111111","serverId":"remote",
     "name":"Modern","origin":"codevisor","createdAt":768000000,
     "locations":[{"id":"22222222-2222-4222-8222-222222222222",
       "projectId":"11111111-1111-4111-8111-111111111111",
       "serverId":"remote","folderPath":"/srv/modern","isGitRepository":true}],
     "folderURL":{"invalid":"legacy URL must be a string"}}
    """,
    [
      ProjectLocation(
        id: "22222222-2222-4222-8222-222222222222",
        projectId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        serverId: "remote",
        folderPath: "/srv/modern",
        isGitRepository: true
      )
    ]
  ),
  (
    """
    {"id":"11111111-1111-4111-8111-111111111111","serverId":"remote",
     "name":"Modern","origin":"codevisor","createdAt":768000000,
     "locations":[],"folderURL":{"invalid":"legacy URL must be a string"}}
    """,
    []
  ),
]

@Suite("Project location decoding")
struct ProjectLocationDecodingTests {
  @Test("Modern locations dominate a malformed legacy folderURL", arguments: modernLocationCases)
  func modernLocationsTakePrecedence(json: String, expected: [ProjectLocation]) throws {
    let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(project.locations == expected)
  }

  @Test("Malformed modern locations throw instead of falling back to a valid legacy folderURL")
  func malformedModernLocationsThrow() throws {
    let json = """
      {"id":"11111111-1111-4111-8111-111111111111","serverId":"remote",
       "name":"Malformed","origin":"codevisor","createdAt":768000000,
       "locations":"not an array","folderURL":"file:///srv/legacy/"}
      """

    do {
      _ = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
      Issue.record("Expected malformed modern locations to throw")
    } catch DecodingError.typeMismatch(_, let context) {
      #expect(context.codingPath.map(\.stringValue) == ["locations"])
    } catch {
      Issue.record("Expected DecodingError.typeMismatch, received \(error)")
    }
  }
}
