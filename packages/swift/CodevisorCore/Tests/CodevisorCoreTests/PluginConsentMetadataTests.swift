import Foundation
import Testing

@testable import CodevisorCore

@Suite("Plugin consent metadata")
struct PluginConsentMetadataTests {
  @Test("Consent names the publisher and a version, as the cloud requires")
  func requiredFields() throws {
    let notion = ServerPluginCatalogEntry(
      id: "com.notion/mcp", name: "Notion", description: "", publisher: "Notion", version: "remote", transport: "http")
    let custom = PluginModerationSubject(
      custom: CustomPluginLocation(transport: "http", url: "https://mcp.example.com/mcp", command: nil, args: []),
      name: "Example")

    let catalog = try encoded(PluginConsentMetadata(notion, ageRating: 4))
    let added = try encoded(PluginConsentMetadata(custom: custom))

    #expect(catalog["publisher"] as? String == "com.notion")
    #expect(catalog["version"] as? String == "remote")
    #expect(added["publisher"] as? String == "mcp.example.com")
    #expect(added["version"] as? String == "custom")
  }

  private func encoded(_ metadata: PluginConsentMetadata) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
  }
}
