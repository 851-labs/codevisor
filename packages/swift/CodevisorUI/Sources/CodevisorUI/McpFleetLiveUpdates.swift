import CodevisorCore
import SwiftUI

public extension View {
  func mcpFleetLiveUpdates(_ model: McpGlobalModel) -> some View {
    modifier(McpFleetLiveUpdates(model: model))
  }
}

private struct McpFleetLiveUpdates: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  let model: McpGlobalModel

  func body(content: Content) -> some View {
    content
      .task(id: environment.machines.allMachines.map(\.id)) { await model.load(in: environment) }
      .onChange(of: stateRevisions) { _, _ in model.scheduleReload(in: environment) }
      .onChange(of: environment.configSync.revisionsByNamespace["mcp-readiness"]) { _, _ in
        model.settle(in: environment)
      }
  }

  private var stateRevisions: [UInt64] {
    environment.machines.allMachines.map { environment.mcpStateRevision(for: $0.id) }
  }
}
