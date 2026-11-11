import AppKit
import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorMirrorsSection: View {
  let mirrors: [ServerWorkspaceMirror]
  @Binding var isExpanded: Bool
  let onRemove: (ServerWorkspaceMirror) -> Void

  var body: some View {
    WorkspaceInspectorCard(title: "Mirrors", isExpanded: $isExpanded) {
      ForEach(mirrors) { mirror in
        WorkspaceInspectorMirrorRow(mirror: mirror, onRemove: { onRemove(mirror) })
      }
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
