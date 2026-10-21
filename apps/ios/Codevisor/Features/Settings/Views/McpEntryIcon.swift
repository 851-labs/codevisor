import CodevisorUI
import SwiftUI

struct McpEntryIcon: View {
  let entry: McpFleetEntry

  var body: some View {
    if entry.kind == "codevisor" {
      CodevisorSymbol.codevisorMark.image
    } else if entry.isBuiltIn {
      Image(systemName: symbolName)
    } else {
      McpServerIconView(entry: entry) {
        Image(systemName: symbolName)
      }
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
