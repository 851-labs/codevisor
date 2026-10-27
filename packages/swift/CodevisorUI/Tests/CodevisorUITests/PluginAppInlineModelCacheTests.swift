import Testing
import TranscriptKit

@testable import CodevisorUI

@MainActor
@Suite("Inline plugin app model cache")
struct PluginAppInlineModelCacheTests {
  private func app(_ viewId: String, machineId: String? = nil) -> CodevisorExecutionApp {
    CodevisorExecutionApp(
      viewId: viewId, machineId: machineId, serverId: "mcp", serverName: "Zillow", toolName: "search",
      resourceUri: "ui://z")
  }

  @Test("A remounted app reuses its loaded model, keyed by the machine that owns it")
  func reuse() {
    let cache = PluginAppInlineModelCache(capacity: 4)

    let first = cache.model(for: app("v1"), chatMachineId: "local")
    let again = cache.model(for: app("v1", machineId: "local"), chatMachineId: "studio")
    let elsewhere = cache.model(for: app("v1"), chatMachineId: "studio")

    #expect(first === again)
    #expect(first !== elsewhere)
  }

  @Test("Only the most recently shown apps keep a live web view")
  func eviction() {
    let cache = PluginAppInlineModelCache(capacity: 2)
    let first = cache.model(for: app("v1"), chatMachineId: "local")
    _ = cache.model(for: app("v2"), chatMachineId: "local")
    _ = cache.model(for: app("v1"), chatMachineId: "local")
    _ = cache.model(for: app("v3"), chatMachineId: "local")

    #expect(cache.cachedKeys == ["local|v1", "local|v3"])
    #expect(cache.model(for: app("v1"), chatMachineId: "local") === first)
  }
}
