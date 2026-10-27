import Foundation

public struct PluginPaneOffer: Identifiable, Equatable, Sendable {
  public let pluginId: String
  public let paneType: String
  public let title: String

  public var id: String { "\(pluginId)|\(paneType)" }

  public init(pluginId: String, paneType: String, title: String) {
    self.pluginId = pluginId
    self.paneType = paneType
    self.title = title
  }

  public static func offers(from plugins: [ServerMcpServer]) -> [PluginPaneOffer] {
    plugins.filter(\.enabled).flatMap(offers(from:))
  }

  private static func offers(from plugin: ServerMcpServer) -> [PluginPaneOffer] {
    (plugin.capabilities?.panes ?? []).map {
      PluginPaneOffer(pluginId: plugin.id, paneType: $0.type, title: $0.title)
    }
  }

  public static func load(from client: any CodevisorServerClienting) async -> [PluginPaneOffer]? {
    guard let plugins = try? await client.listMcpServers() else { return nil }
    return offers(from: plugins)
  }
}
