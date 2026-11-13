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
  @State private var latency: (serverId: String, milliseconds: Double)?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if let desktop {
          WorkspaceInspectorCard(title: "Desktop", isExpanded: desktopExpansion) {
            MachineDesktopPreview(
              session: desktop, isStreaming: isActive && desktopExpansion.wrappedValue, onOpen: onOpenDesktop
            )
            .id(ObjectIdentifier(desktop))
          }
        }
        if let stats, stats.serverId == serverId {
          WorkspaceInspectorMachineSection(
            stats: stats.stats, latencyMilliseconds: latencyMilliseconds, isExpanded: statsExpansion)
        }
      }
      .padding(.vertical, 10)
    }
    .task(id: isActive ? serverId : nil) { await pollStats() }
  }

  private var latencyMilliseconds: Double? {
    guard let latency, latency.serverId == serverId else { return nil }
    return latency.milliseconds
  }

  private func pollStats() async {
    guard isActive else { return }
    await refreshStats(animated: false)
    while await waitForNextRefresh() {
      await refreshStats(animated: true)
    }
  }

  private func refreshStats(animated: Bool) async {
    let serverId = serverId
    let milliseconds = await Self.measureLatency(client)
    let latest = try? await client.machineStats()
    guard !Task.isCancelled else { return }

    withTransaction(\.disablesAnimations, !animated) {
      if let milliseconds { latency = (serverId, milliseconds) }
      if let latest { stats = (serverId, latest) }
    }
  }

  private func waitForNextRefresh() async -> Bool {
    (try? await Task.sleep(for: WorkspaceInspectorMachineSection.refreshInterval)) != nil
  }

  @concurrent
  private nonisolated static func measureLatency(_ client: any CodevisorServerClienting) async -> Double? {
    let clock = ContinuousClock()
    let start = clock.now
    guard (try? await client.health()) != nil else { return nil }

    return start.duration(to: clock.now) / .milliseconds(1)
  }
}
