import CodevisorCore
import SwiftUI

/// An archived chat retains its title and project context for restoration.
struct SidebarArchivedSessionRow: View {
  @Environment(AppEnvironment.self) private var environment

  let session: ChatSession
  let project: Project
  let store: SessionStore?
  let isReordering: Bool
  let titleFont: Font
  let onRestore: () -> Void

  var body: some View {
    HoverableRow(isHoverEnabled: !isReordering) { _ in
      HStack(spacing: 7) {
        ChatSessionLeadingIcon(session: session, store: store, activityColor: .secondary)
          .frame(width: 18)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(session.title)
            .font(titleFont)
            .lineLimit(1)
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .foregroundStyle(.secondary)
      .onTapGesture(perform: onRestore)
    }
    .contextMenu {
      Button(action: onRestore) {
        Label("Restore", systemImage: "arrow.uturn.backward")
          .labelStyle(.titleAndIcon)
      }
    }
  }

  private var subtitle: String {
    let machineName = environment.machines.fleetMachineName(for: session.serverId)
    let projectName: String? = project.isScratch ? nil : project.name
    return [projectName, session.worktreeName, machineName]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
}
