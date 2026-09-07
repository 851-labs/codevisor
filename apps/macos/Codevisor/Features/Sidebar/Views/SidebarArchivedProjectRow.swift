import CodevisorCore
import CodevisorUI
import SwiftUI

/// An archived project opens a restore confirmation from its row or menu.
struct SidebarArchivedProjectRow: View {
  let project: Project
  let isReordering: Bool
  let titleFont: Font
  let onRestore: () -> Void

  var body: some View {
    HoverableRow(isHoverEnabled: !isReordering) { _ in
      Button(action: onRestore) {
        HStack(spacing: 6) {
          Image(systemName: EntitySystemSymbol.project)
            .frame(width: 18)
          Text(project.name)
            .font(titleFont)
            .lineLimit(1)
          Spacer(minLength: 6)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .help(project.folderURL.path)
    .contextMenu {
      Button(action: onRestore) {
        Label("Restore", systemImage: "arrow.uturn.backward")
          .labelStyle(.titleAndIcon)
      }
    }
  }
}
