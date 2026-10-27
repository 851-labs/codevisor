import Foundation
import Testing

@testable import CodevisorCore

struct PluginPaneOfferTests {
  @Test("Enabled plugins offer one tab per declared pane; disabled and pane-less plugins offer none")
  func offersFollowCapabilities() throws {
    let plugins = try JSONDecoder().decode(
      [ServerMcpServer].self,
      from: Data(
        """
        [\(Self.plugin(id: "g", enabled: true, panes: #"[{"type":"a","title":"Alerts","resourceUri":"ui://g/a"},{"type":"b","title":"Board","resourceUri":"ui://g/b"}]"#)),
        \(Self.plugin(id: "off", enabled: false, panes: #"[{"type":"x","title":"X","resourceUri":"ui://x"}]"#)),
        \(Self.plugin(id: "bare", enabled: true, panes: nil))]
        """.utf8))

    let offers = PluginPaneOffer.offers(from: plugins)

    #expect(
      offers == [
        PluginPaneOffer(pluginId: "g", paneType: "a", title: "Alerts"),
        PluginPaneOffer(pluginId: "g", paneType: "b", title: "Board"),
      ])
    #expect(offers.map(\.id) == ["g|a", "g|b"])
  }

  private static func plugin(id: String, enabled: Bool, panes: String?) -> String {
    let capabilities = panes.map { #","capabilities":{"tools":[],"panes":\#($0)}"# } ?? ""
    return """
      {"id":"\(id)","name":"\(id)","transport":"stdio","args":[],"enabled":\(enabled),"authType":"none",\
      "connectionState":"connected","toolCount":0,"createdAt":"","updatedAt":""\(capabilities)}
      """
  }
}
