import CodevisorCore
import SwiftUI

/// An MCP server's own icon in Settings: its declared `serverInfo` icon,
/// else its brand's favicon, resolved by a machine that has the server
/// (this one when it can) and cached like transcript tool icons. Draws
/// `fallback` until then, or when there is none.
public struct McpServerIconView<Fallback: View>: View {
  let entry: McpFleetEntry
  let side: CGFloat
  let fallback: Fallback

  @Environment(AppEnvironment.self) private var environment
  @Environment(\.colorScheme) private var colorScheme

  public init(entry: McpFleetEntry, side: CGFloat = 18, @ViewBuilder fallback: () -> Fallback) {
    self.entry = entry
    self.side = side
    self.fallback = fallback()
  }

  /// The machine asked for the icon, and the server's id there.
  private var source: (machineId: String, serverId: String)? {
    if let local = entry.idByMachine[CodevisorMachine.local.id] {
      return (CodevisorMachine.local.id, local)
    }
    return entry.idByMachine.min { $0.key < $1.key }.map { ($0.key, $0.value) }
  }

  public var body: some View {
    let source = source
    let host = entry.representative.url.flatMap(URL.init(string:))?.host()
    ToolArtworkImage(
      request: source.map {
        ToolIconImages.Request(
          namespace: $0.machineId,
          artwork: .mcpServer(id: $0.serverId, host: host),
          dark: colorScheme == .dark
        )
      },
      side: side,
      fetch: { [environment] request in
        guard let machineId = source?.machineId else { throw CodevisorServerClientError.invalidResponse }
        return try await environment.machines.client(for: machineId).toolIcon(request)
      }
    ) {
      fallback
    }
  }
}
