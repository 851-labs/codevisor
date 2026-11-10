import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorSyncsSection: View {
  let workspaceId: UUID
  let client: any CodevisorServerClienting
  @Binding var isExpanded: Bool

  @State private var syncs: [ServerWorkspaceSync] = []

  private static let refreshInterval = Duration.seconds(5)

  var body: some View {
    VStack(spacing: 0) {
      if !syncs.isEmpty {
        WorkspaceInspectorCard(title: "Synced To", isExpanded: $isExpanded) {
          ForEach(syncs) { sync in
            WorkspaceInspectorSyncRow(sync: sync, onRemove: { remove(sync) })
          }
        }
      }
    }
    .task(id: workspaceId) { await keepLoading() }
  }

  private func keepLoading() async {
    while !Task.isCancelled {
      await load()
      try? await Task.sleep(for: Self.refreshInterval)
    }
  }

  private func load() async {
    guard let loaded = try? await client.workspaceSyncs(workspaceId: workspaceId) else { return }
    syncs = loaded
  }

  private func remove(_ sync: ServerWorkspaceSync) {
    syncs.removeAll { $0.id == sync.id }
    Task {
      try? await client.stopWorkspaceSync(workspaceId: workspaceId, machineId: sync.machine.machineId)
      await load()
    }
  }
}

private struct WorkspaceInspectorSyncRow: View {
  let sync: ServerWorkspaceSync
  let onRemove: () -> Void
  @Environment(AppEnvironment.self) private var environment

  private var machineId: String {
    environment.machines.machineId(forSyncKey: sync.machine.machineId) ?? sync.machine.machineId
  }

  private var status: FleetRowStatus {
    switch sync.state {
    case .synced: .ready("Up to date")
    case .syncing: .syncing
    case .failed: .attention("Sync failed", reason: sync.error ?? "")
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        if let path = sync.path {
          Button("Copy Path") { copy(path) }
          Divider()
        }
        Button("Remove Files", role: .destructive, action: onRemove)
      } label: {
        Label {
          Text(sync.machine.name)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
          MachineIconView(machineId: machineId)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .help(sync.path ?? sync.machine.name)
      FleetStatusMark(status: status)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(sync.machine.name), \(status.label)")
    .accessibilityAction(named: "Remove Files", onRemove)
  }

  private func copy(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }
}
