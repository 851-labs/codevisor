import CodevisorCore
import SwiftUI

public struct PluginIconView: View {
  private let pluginId: String
  private let client: any CodevisorServerClienting
  private let cacheNamespace: String
  private let side: CGFloat
  private let fallbackSystemName: String

  @Environment(\.colorScheme) private var colorScheme

  public init(
    pluginId: String,
    client: any CodevisorServerClienting,
    cacheNamespace: String,
    side: CGFloat,
    fallbackSystemName: String = "puzzlepiece.extension"
  ) {
    self.pluginId = pluginId
    self.client = client
    self.cacheNamespace = cacheNamespace
    self.side = side
    self.fallbackSystemName = fallbackSystemName
  }

  public var body: some View {
    ToolArtworkImage(
      request: ToolIconImages.Request(
        namespace: cacheNamespace,
        artwork: .mcpServer(id: pluginId, host: nil),
        dark: colorScheme == .dark
      ),
      side: side,
      fetch: { [client] request in try await client.toolIcon(request) }
    ) {
      Image(systemName: fallbackSystemName)
    }
  }
}
