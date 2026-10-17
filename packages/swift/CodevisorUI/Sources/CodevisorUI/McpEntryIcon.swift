import SwiftUI

public struct McpEntryIcon: View {
  private let entry: McpFleetEntry

  public init(entry: McpFleetEntry) {
    self.entry = entry
  }

  public var body: some View {
    if entry.kind == "codevisor" {
      Image("CodevisorMark")
        .resizable()
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .frame(width: 16, height: 16)
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
