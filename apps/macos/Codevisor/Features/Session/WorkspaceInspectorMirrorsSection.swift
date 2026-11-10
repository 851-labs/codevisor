import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorMirrorsSection: View {
  let workspaceId: UUID
  let client: any CodevisorServerClienting
  @Binding var isExpanded: Bool

  @State private var mirrors: [ServerWorkspaceMirror] = []

  private static let refreshInterval = Duration.seconds(5)

  var body: some View {
    VStack(spacing: 0) {
      if !mirrors.isEmpty {
        WorkspaceInspectorCard(title: "Mirrors", isExpanded: $isExpanded) {
          ForEach(mirrors) { mirror in
            WorkspaceInspectorMirrorRow(mirror: mirror, onRemove: { remove(mirror) })
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
    guard let loaded = try? await client.workspaceMirrors(workspaceId: workspaceId) else { return }
    mirrors = loaded
  }

  private func remove(_ mirror: ServerWorkspaceMirror) {
    mirrors.removeAll { $0.id == mirror.id }
    Task {
      try? await client.stopWorkspaceMirror(workspaceId: workspaceId, machineId: mirror.machine.machineId)
      await load()
    }
  }
}

private struct WorkspaceInspectorMirrorRow: View {
  let mirror: ServerWorkspaceMirror
  let onRemove: () -> Void
  @Environment(AppEnvironment.self) private var environment

  private var machineId: String {
    environment.machines.machineId(forSyncKey: mirror.machine.machineId) ?? mirror.machine.machineId
  }

  private var status: FleetRowStatus {
    switch mirror.state {
    case .synced: .ready("Up to date")
    case .syncing: .syncing
    case .failed: .attention("Sync failed", reason: mirror.error ?? "")
    }
  }

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        if let path = mirror.path {
          Button("Copy Path") { copy(path) }
          Divider()
        }
        Button("Remove Files", role: .destructive, action: onRemove)
      } label: {
        Label {
          Text(mirror.machine.name)
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
      .help(mirror.path ?? mirror.machine.name)
      FleetStatusMark(status: status)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(mirror.machine.name), \(status.label)")
    .accessibilityAction(named: "Remove Files", onRemove)
  }

  private func copy(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }
}
