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

  @Test("Consent sends how many tools a plugin has, not their descriptions, so a large plugin still fits")
  func capabilityCounts() throws {
    let tools = (0..<83).map {
      ServerPluginToolDigest(name: "tool_\($0)", description: String(repeating: "Long description. ", count: 40))
    }
    let linear = ServerPluginCatalogEntry(
      id: "dev.codevisor/linear", name: "Linear", description: "", publisher: "Codevisor", version: "1.0.0",
      transport: "stdio", capabilities: ServerPluginCapabilities(tools: tools))

    let metadata = PluginConsentMetadata(linear, ageRating: 4)
    let counts = try #require(try encoded(metadata)["capabilities"] as? [String: Int])

    #expect(counts == ["tools": 83, "events": 0, "skills": 0, "panes": 0, "ingress": 0])
    #expect(try JSONEncoder().encode(metadata).count < 1024)
  }

  private func encoded(_ metadata: PluginConsentMetadata) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
  }
}
