import Foundation
import Testing
@testable import CodevisorCore

@Suite("iOS plugin access policy")
struct PluginAccessPolicyTests {
  private func policy(_ fields: String = "") throws -> PluginAccessPolicy {
    let json = "{\"supportedAgeRating\":16,\"blocks\":[],\"ageRatings\":[]\(fields)}"
    return try JSONDecoder().decode(PluginAccessPolicy.self, from: Data(json.utf8))
  }

  @Test("Accepts declared supported ratings and rejects missing and mature ratings")
  func ageRatings() throws {
    let policy = try policy()
    for age in [4, 9, 13, 16] {
      #expect(policy.restriction(pluginId: "acme.notes", ageRating: age, blockedPublishers: []) == nil)
    }
    for age in [nil, 0, 17, 18] as [Int?] {
      #expect(policy.restriction(pluginId: "acme.notes", ageRating: age, blockedPublishers: []) != nil)
    }
  }

  @Test("Moderator and user publisher blocks take precedence over declared ratings")
  func blocks() throws {
    let data = Data(
      """
      {"supportedAgeRating":16,"blocks":[
        {"targetKind":"plugin","target":"acme.notes","reason":"reviewed"},
        {"targetKind":"publisher","target":"abusive","reason":"reviewed"}
      ],"ageRatings":[{"pluginId":"acme.adult","minimumAge":18}]}
      """.utf8)
    let policy = try JSONDecoder().decode(PluginAccessPolicy.self, from: data)
    for id in ["acme.notes", "abusive.other", "acme.adult", "muted.notes"] {
      #expect(policy.restriction(pluginId: id, ageRating: 4, blockedPublishers: ["muted"]) != nil)
    }
    #expect(policy.restriction(pluginId: "acme.safe", ageRating: 4, blockedPublishers: ["muted"]) == nil)
  }

  @Test("The server cannot raise the age ceiling above the app rating")
  func fixedCeiling() throws {
    var policy = try policy()
    policy.supportedAgeRating = 18
    #expect(policy.restriction(pluginId: "acme.adult", ageRating: 18, blockedPublishers: []) != nil)
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
    #expect(
      policy.restriction(
        pluginId: "muted.notes", ageRating: 4,
        blockedPublishers: preferences.blockedPublishers) != nil)
    #expect(
      policy.restriction(
        pluginId: "acme.notes", ageRating: 4,
        blockedPublishers: preferences.blockedPublishers) == nil)
  }
}
