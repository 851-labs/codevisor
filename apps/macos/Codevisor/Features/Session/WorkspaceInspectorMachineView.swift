import CodevisorClient
import SwiftUI

struct WorkspaceInspectorMachineView: View {
  let serverId: String
  let isActive: Bool
  let client: any CodevisorServerClienting
  let desktop: MachineDesktopSession?
  let desktopExpansion: Binding<Bool>
  let statsExpansion: Binding<Bool>
  let onOpenDesktop: () -> Void
  @State private var stats: (serverId: String, stats: ServerMachineStats)?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if let desktop {
          WorkspaceInspectorCard(title: "Desktop", isExpanded: desktopExpansion) {
            MachineDesktopPreview(
              session: desktop, isStreaming: isActive, onOpen: onOpenDesktop
            )
            .id(ObjectIdentifier(desktop))
          }
        }
        if let stats, stats.serverId == serverId {
          WorkspaceInspectorMachineSection(stats: stats.stats, isExpanded: statsExpansion)
        }
      }
      .padding(.vertical, 10)
    }
    .task(id: isActive ? serverId : nil) { await pollStats() }
  }

  private func pollStats() async {
    guard isActive else { return }
    let serverId = serverId
    while !Task.isCancelled {
      if let latest = try? await client.machineStats(), !Task.isCancelled {
        stats = (serverId, latest)
      }
      try? await Task.sleep(for: WorkspaceInspectorMachineSection.refreshInterval)
    }
  }
}
