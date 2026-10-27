import Foundation
import Testing

@testable import CodevisorClient

@Suite("Plugin catalog universal links")
struct PluginCatalogLinkTests {
  @Test("Codevisor plugin pages name a catalog id, including encoded registry names")
  func acceptsPluginPages() throws {
    for host in ["codevisor.dev", "www.codevisor.dev"] {
      let url = try #require(URL(string: "https://\(host)/plugins/io.github.acme%2Fnotes"))
      #expect(PluginCatalogLink.catalogId(from: url) == "io.github.acme/notes")
    }
    let firstParty = try #require(URL(string: "https://www.codevisor.dev/plugins/grafana"))
    #expect(PluginCatalogLink.catalogId(from: firstParty) == "grafana")
  }

  @Test("Other hosts, schemes, paths and traversal are ignored")
  func rejectsEverythingElse() throws {
    for raw in [
      "http://codevisor.dev/plugins/grafana", "https://evil.example/plugins/grafana",
      "https://codevisor.dev/plugins/grafana/extra", "https://codevisor.dev/plugins/..%2Fterms",
      "https://user@codevisor.dev/plugins/grafana", "https://codevisor.dev:8443/plugins/grafana",
      "https://codevisor.dev/terms",
    ] {
      #expect(PluginCatalogLink.catalogId(from: try #require(URL(string: raw))) == nil)
    }
  }
}
