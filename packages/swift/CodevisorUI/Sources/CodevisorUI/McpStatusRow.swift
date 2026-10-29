import CodevisorCore
import SwiftUI

public struct McpStatusRow: View {
  @Environment(AppEnvironment.self) private var environment
  private let entry: McpFleetEntry
  private let model: McpGlobalModel

  public init(entry: McpFleetEntry, model: McpGlobalModel) {
    self.entry = entry
    self.model = model
  }

  public var body: some View {
    LabeledContent("Status", value: McpFleetSummary(entry: entry, rows: model.rows(for: entry, in: environment)).label)
    if let message = model.actionError {
      Text(message).foregroundStyle(.red)
    }
  }
}
