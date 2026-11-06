import CodevisorUI
import SwiftUI

struct FloatingPaneHeader: View {
  let title: String
  let actions: FloatingPaneActions

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.tabLabel(weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      actionsMenu
      closeButton
    }
    .padding(.leading, 12)
    .padding(.trailing, 6)
    .frame(height: 30)
    .contentShape(Rectangle())
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var actionsMenu: some View {
    Menu {
      Button(action: actions.returnToWorkspace) {
        Label("Return to Workspace", systemImage: "pip.exit")
          .labelStyle(.titleAndIcon)
      }
      Divider()
      Button(role: .destructive, action: actions.close) {
        Label("Close", systemImage: "xmark")
          .labelStyle(.titleAndIcon)
      }
      .shortcut(.closeSplit)
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Floating pane actions")
    .accessibilityLabel("Floating pane actions")
  }

  private var closeButton: some View {
    Button(action: actions.close) {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Close")
    .accessibilityLabel("Close \(title)")
  }
}
