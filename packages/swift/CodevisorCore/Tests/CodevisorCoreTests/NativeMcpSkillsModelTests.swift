import Foundation
import Testing
@testable import CodevisorCore

@Suite("Native MCP and skills wire models")
struct NativeMcpSkillsModelTests {
  private let decoder = JSONDecoder()

  @Test("decodes a native MCP scan with optional fields absent")
  func decodesNativeMcpScan() throws {
    let json = """
      {
        "candidates": [
          {
            "identity": "docs-mcp",
            "name": "docs",
            "transport": "stdio",
            "command": "npx",
            "args": ["-y", "docs-mcp"],
            "foundIn": ["claude-code", "codex"],
            "alreadyManaged": false
          }
        ],
        "harnesses": [
          {
            "harnessId": "claude-code",
            "harnessName": "Claude Code",
            "configPath": "/home/u/.claude.json",
            "exists": true,
            "servers": [
              {
                "harnessId": "claude-code",
                "harnessName": "Claude Code",
                "serverName": "docs",
                "scope": "global",
                "configPath": "/home/u/.claude.json",
                "transport": "stdio",
                "command": "npx",
                "args": ["-y", "docs-mcp"],
                "envNames": ["TOKEN"],
                "headerNames": [],
                "supportsDisable": false,
                "supportsRemove": true,
                "identity": "docs-mcp",
                "alreadyManaged": false
              }
            ]
          }
        ]
      }
      """
    let scan = try decoder.decode(ServerNativeMcpScan.self, from: Data(json.utf8))
    #expect(scan.candidates.count == 1)
    #expect(scan.candidates[0].foundIn == ["claude-code", "codex"])
    #expect(scan.candidates[0].url == nil)
    let server = try #require(scan.harnesses.first?.servers.first)
    #expect(server.enabled == nil)
    #expect(server.envNames == ["TOKEN"])
    #expect(server.supportsRemove)
    #expect(scan.harnesses[0].error == nil)
    // Identifiable ids are stable and unique per harness/scope/file/name.
    #expect(server.id == "claude-code|global|/home/u/.claude.json|docs")
  }

  @Test("decodes per-harness scan errors and enable flags")
  func decodesScanErrors() throws {
    let json = """
      {
        "candidates": [],
        "harnesses": [
          {
            "harnessId": "opencode",
            "harnessName": "OpenCode",
            "configPath": "/xdg/opencode/opencode.json",
            "exists": true,
            "error": "invalid JSON at offset 3",
            "servers": [
              {
                "harnessId": "opencode",
                "harnessName": "OpenCode",
                "serverName": "local",
                "scope": "global",
                "configPath": "/xdg/opencode/opencode.json",
                "transport": "http",
                "url": "https://mcp.example.com",
                "args": [],
                "envNames": [],
                "headerNames": [],
                "enabled": false,
                "supportsDisable": true,
                "supportsRemove": true,
                "identity": "https://mcp.example.com",
                "alreadyManaged": true
              }
            ]
          }
        ]
      }
      """
    let scan = try decoder.decode(ServerNativeMcpScan.self, from: Data(json.utf8))
    #expect(scan.harnesses[0].error == "invalid JSON at offset 3")
    let server = try #require(scan.harnesses.first?.servers.first)
    #expect(server.enabled == false)
    #expect(server.supportsDisable)
    #expect(server.alreadyManaged)
  }

  @Test("decodes import results with mixed outcomes")
  func decodesImportResult() throws {
    let json = """
      {
        "outcomes": [
          {
            "identity": "docs-mcp",
            "status": "imported",
            "serverId": "abc",
            "serverName": "docs",
            "warnings": ["TOKEN references a shell variable and was imported verbatim"]
          },
          { "identity": "ghost", "status": "failed", "detail": "Not found", "warnings": [] }
        ],
        "scan": { "candidates": [], "harnesses": [] }
      }
      """
    let result = try decoder.decode(ServerNativeMcpImportResult.self, from: Data(json.utf8))
    #expect(result.outcomes.count == 2)
    #expect(result.outcomes[0].serverName == "docs")
    #expect(result.outcomes[0].warnings.count == 1)
    #expect(result.outcomes[1].status == "failed")
    #expect(result.outcomes[1].detail == "Not found")
    #expect(result.scan.candidates.isEmpty)
  }

  @Test("decodes removal results")
  func decodesRemovalResult() throws {
    let json = """
      {
        "removal": {
          "id": "removal-1",
          "harnessId": "claude-code",
          "configPath": "/home/u/.claude.json",
          "serverName": "docs",
          "removedAt": "2026-07-20T00:00:00.000Z"
        },
        "scan": { "candidates": [], "harnesses": [] }
      }
      """
    let result = try decoder.decode(ServerRemoveNativeMcpResult.self, from: Data(json.utf8))
    #expect(result.removal.serverName == "docs")
    #expect(result.removal.restoredAt == nil)
    #expect(result.scan.harnesses.isEmpty)
  }

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
