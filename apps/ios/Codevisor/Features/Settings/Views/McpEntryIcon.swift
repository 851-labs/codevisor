import CodevisorUI
import SwiftUI

/// A server's artwork in the MCP list. The Codevisor gateway gets the
/// product mark — it is Codevisor's own tools, not a third-party server, and
/// a generic glyph made it look like one. The mark lives in the app's asset
/// catalog rather than the shared package, which is why the list takes its
/// icon from the app.
struct McpEntryIcon: View {
  let entry: McpFleetEntry

  var body: some View {
    if entry.kind == "codevisor" {
      Image("CodevisorMark")
        .resizable()
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .frame(width: 16, height: 16)
    } else {
      Image(systemName: symbolName)
    }
  }

  private var symbolName: String {
    switch entry.kind {
    case "computerUse": "display"
    case "browserUse": "globe"
    default: entry.transport == "stdio" ? "terminal" : "point.3.connected.trianglepath.dotted"
    }
  }
}
