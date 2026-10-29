import CodevisorCore
import SwiftUI

struct PluginCatalogIcon: View {
  @Environment(\.colorScheme) private var colorScheme
  let pluginId: String
  let name: String
  let host: String?
  let namespace: String
  let client: any CodevisorServerClienting
  let side: CGFloat

  init(entry: ServerPluginCatalogEntry, client: any CodevisorServerClienting, side: CGFloat) {
    self.init(
      pluginId: entry.id, name: entry.name, host: entry.url.flatMap { URL(string: $0)?.host() },
      namespace: "plugin-catalog", client: client, side: side)
  }

  init(
    pluginId: String, name: String, host: String?, namespace: String, client: any CodevisorServerClienting,
    side: CGFloat
  ) {
    self.pluginId = pluginId
    self.name = name
    self.host = host
    self.namespace = namespace
    self.client = client
    self.side = side
  }

  var body: some View {
    ToolArtworkImage(
      request: ToolIconImages.Request(
        namespace: namespace,
        artwork: .mcpServer(id: pluginId, host: host),
        dark: colorScheme == .dark
      ),
      side: side,
      fetch: { [client] request in try await client.toolIcon(request) }
    ) {
      PluginMonogram(name: name, side: side)
    }
    .frame(width: side, height: side)
    .accessibilityHidden(true)
  }
}

private struct PluginMonogram: View {
  let name: String
  let side: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: side / 4, style: .continuous)
      .fill(.quaternary)
      .overlay {
        Text(name.first.map { String($0).uppercased() } ?? "")
          .font(.system(size: side * 0.45, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary)
      }
  }
}
