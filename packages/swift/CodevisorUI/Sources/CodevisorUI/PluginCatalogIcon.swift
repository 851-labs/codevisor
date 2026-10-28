import CodevisorCore
import SwiftUI

struct PluginCatalogIcon: View {
  @Environment(\.colorScheme) private var colorScheme
  let entry: ServerPluginCatalogEntry
  let client: any CodevisorServerClienting
  let side: CGFloat

  var body: some View {
    ToolArtworkImage(
      request: ToolIconImages.Request(
        namespace: "plugin-catalog",
        artwork: .mcpServer(id: entry.id, host: entry.url.flatMap { URL(string: $0)?.host() }),
        dark: colorScheme == .dark
      ),
      side: side,
      fetch: { [client] request in try await client.toolIcon(request) }
    ) {
      PluginMonogram(name: entry.name, side: side)
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
