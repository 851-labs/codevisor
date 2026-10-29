import CodevisorCore
import SwiftUI

public struct McpFleetSection<Row: View>: View {
  private let model: McpGlobalModel
  private let builtIn: Bool
  private let row: (McpFleetEntry) -> Row

  public init(
    model: McpGlobalModel, builtIn: Bool, @ViewBuilder row: @escaping (McpFleetEntry) -> Row
  ) {
    self.model = model
    self.builtIn = builtIn
    self.row = row
  }

  public var body: some View {
    let entries = builtIn ? model.builtIns : model.managed
    ForEach(entries) { entry in
      row(entry)
    }
    if entries.isEmpty && !builtIn {
      Text(model.isLoading ? "Loading…" : "No plugins added yet.")
        .foregroundStyle(.secondary)
    }
  }
}
