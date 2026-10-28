import Foundation
import Testing

@testable import CodevisorCore

@Suite("Plugin moderation identity")
struct PluginModerationSubjectTests {
  @Test("Catalog plugins use their registry name, with the namespace as publisher")
  func catalogIdentity() {
    let entry = ServerPluginCatalogEntry(
      id: "io.github.Acme/notes", name: "Notes", description: "", publisher: "Acme", version: "1.2.0",
      transport: "stdio", ageRating: 4)

    let subject = PluginModerationSubject(catalogEntry: entry)

    #expect(subject.pluginId == "io.github.Acme/notes")
    #expect(subject.publisher == "io.github.acme")
    #expect(subject.declaredAgeRating == 4)
    let isHex = subject.consentKey.allSatisfy { $0.isHexDigit }
    #expect(subject.consentKey.count == 64)
    #expect(isHex)
  }

  @Test("A new catalog version asks for consent again")
  func consentFollowsVersion() {
    let older = PluginModerationSubject(
      pluginId: "a/b", name: "B", publisher: "a", declaredAgeRating: nil, revision: "1")
    let newer = PluginModerationSubject(
      pluginId: "a/b", name: "B", publisher: "a", declaredAgeRating: nil, revision: "2")

    #expect(older.consentKey != newer.consentKey)
  }

  @Test("Hand-added plugins are identified by host or by command line")
  func customIdentity() {
    let remote = CustomPluginLocation(transport: "http", url: "https://MCP.Example.com/sse", command: nil, args: [])
    let local = CustomPluginLocation(transport: "stdio", url: nil, command: "/usr/local/bin/npx", args: ["-y", "pkg"])

    #expect(PluginModerationSubject(custom: remote, name: "Ex").pluginId == "custom:mcp.example.com")
    #expect(remote.publisher == "mcp.example.com")
    #expect(PluginModerationSubject(custom: local, name: "Pkg").pluginId == "custom:/usr/local/bin/npx -y pkg")
    #expect(local.publisher == "npx")
  }

  @Test("Installed rows map to the catalog id when they came from the catalog")
  func installedIdentity() throws {
    let wire = """
      {"id":"m","name":"Grafana","transport":"stdio","args":[],"enabled":true,"authType":"none",\
      "connectionState":"connected","toolCount":0,"catalogId":"dev.codevisor/grafana","catalogVersion":"1",\
      "ageRating":13,"createdAt":"","updatedAt":""}
      """
    let server = try JSONDecoder().decode(ServerMcpServer.self, from: Data(wire.utf8))

    let subject = PluginModerationSubject(server: server)

    #expect(subject.pluginId == "dev.codevisor/grafana")
    #expect(subject.publisher == "dev.codevisor")
    #expect(subject.declaredAgeRating == 13)
  }

  @Test("Only plain publisher names can be blocked")
  @MainActor
  func publisherValidation() {
    #expect(PluginAccessController.isValidPublisher("io.github.acme"))
    #expect(!PluginAccessController.isValidPublisher(""))
    #expect(!PluginAccessController.isValidPublisher("a/b"))
  }
}
