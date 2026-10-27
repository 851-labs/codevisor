import Foundation
import Testing

@testable import CodevisorCore

@Suite("iOS plugin access policy")
struct PluginAccessPolicyTests {
  private func policy(_ fields: String = "") throws -> PluginAccessPolicy {
    let json = "{\"supportedAgeRating\":16,\"blocks\":[],\"ageRatings\":[]\(fields)}"
    return try JSONDecoder().decode(PluginAccessPolicy.self, from: Data(json.utf8))
  }

  private func subject(_ id: String, age: Int?) -> PluginModerationSubject {
    PluginModerationSubject(
      pluginId: id, name: id, publisher: PluginModerationSubject.publisher(ofCatalogId: id),
      declaredAgeRating: age, revision: "1")
  }

  @Test("Accepts declared supported ratings and rejects missing and mature ratings")
  func ageRatings() throws {
    let policy = try policy()
    for age in [4, 9, 13, 16] {
      #expect(policy.restriction(for: subject("acme/notes", age: age), blockedPublishers: []) == nil)
    }
    for age in [nil, 0, 17, 18] as [Int?] {
      #expect(policy.restriction(for: subject("acme/notes", age: age), blockedPublishers: []) != nil)
    }
  }

  @Test("Moderator and user publisher blocks take precedence over declared ratings")
  func blocks() throws {
    let data = Data(
      """
      {"supportedAgeRating":16,"blocks":[
        {"targetKind":"plugin","target":"acme/notes","reason":"reviewed"},
        {"targetKind":"publisher","target":"abusive","reason":"reviewed"}
      ],"ageRatings":[{"pluginId":"acme/adult","minimumAge":18}]}
      """.utf8)
    let policy = try JSONDecoder().decode(PluginAccessPolicy.self, from: data)
    for id in ["acme/notes", "abusive/other", "acme/adult", "muted/notes"] {
      #expect(policy.restriction(for: subject(id, age: 4), blockedPublishers: ["muted"]) != nil)
    }
    #expect(policy.restriction(for: subject("acme/safe", age: 4), blockedPublishers: ["muted"]) == nil)
  }

  @Test("Plugins the user added by hand skip the age gate but still honor blocks")
  func customPlugins() throws {
    let data = Data(
      #"{"supportedAgeRating":16,"blocks":[{"targetKind":"publisher","target":"bad.example","reason":"r"}],"ageRatings":[]}"#
        .utf8)
    let policy = try JSONDecoder().decode(PluginAccessPolicy.self, from: data)
    let own = PluginModerationSubject(
      custom: CustomPluginLocation(transport: "http", url: "https://mcp.mine.dev", command: nil, args: []), name: "Mine"
    )
    let flagged = PluginModerationSubject(
      custom: CustomPluginLocation(transport: "http", url: "https://bad.example", command: nil, args: []), name: "Bad")

    #expect(policy.restriction(for: own, blockedPublishers: []) == nil)
    #expect(policy.restriction(for: own, blockedPublishers: ["mcp.mine.dev"]) != nil)
    #expect(policy.restriction(for: flagged, blockedPublishers: []) != nil)
    #expect(policy.restriction(for: subject("io.github.acme/raw", age: nil), blockedPublishers: []) != nil)
  }

  @Test("The server cannot raise the age ceiling above the app rating")
  func fixedCeiling() throws {
    var policy = try policy()
    policy.supportedAgeRating = 18
    #expect(policy.restriction(for: subject("acme/adult", age: 18), blockedPublishers: []) != nil)
  }

  @Test(
    "Publisher restrictions work without consent history",
    arguments: [
      "{\"blockedPublishers\":[\"muted\"]}",
      "{\"blockedPublishers\":[\"muted\"],\"consents\":[]}",
    ])
  func preferencesWithoutConsent(json: String) throws {
    let preferences = try JSONDecoder().decode(PluginPreferences.self, from: Data(json.utf8))
    let policy = try policy()
    let blocked = preferences.blockedPublishers
    #expect(policy.restriction(for: subject("muted/notes", age: 4), blockedPublishers: blocked) != nil)
    #expect(policy.restriction(for: subject("acme/notes", age: 4), blockedPublishers: blocked) == nil)
  }
}
