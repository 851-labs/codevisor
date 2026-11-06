import CodevisorCore
import CodevisorUI
import SwiftUI

struct FloatingPaneHeader: View {
  let pane: PaneDescriptorState?
  let title: String
  let source: PaneToolbarSource?
  let sessionStore: SessionStore?
  let coordinateSpace: String
  let actions: FloatingPaneActions
  let drag: FloatingPaneDrag

  @State private var renameText = ""
  @State private var showingRename = false

  private static let minimumDragWidth: CGFloat = 28

  var body: some View {
    HStack(spacing: 6) {
      toolbar(.leading)
      if source?.replacesTitle == true {
        toolbar(.principal)
          .layoutPriority(1)
        dragArea { Color.clear.frame(minWidth: Self.minimumDragWidth, maxWidth: .infinity) }
      } else {
        dragArea { titleText }
      }
      FloatingPaneTrailingToolbar { toolbar(.trailing) }
      actionsMenu
      closeButton
    }
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .frame(height: 36)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .modifier(
      PaneRenameAlert(kind: pane?.kind, isPresented: $showingRename, text: $renameText, onRename: actions.rename))
  }

  @ViewBuilder
  private func toolbar(_ slot: PaneHeaderToolbar.Slot) -> some View {
    if let source {
      PaneHeaderToolbar(source: source, slot: slot, onNewTab: actions.newTab)
    }
  }

  private var titleText: some View {
    Text(title)
      .font(.tabLabel(weight: .medium))
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(minWidth: Self.minimumDragWidth, maxWidth: .infinity, alignment: .leading)
  }

  private func dragArea(@ViewBuilder content: () -> some View) -> some View {
    content()
      .contentShape(Rectangle())
      .layoutPriority(-1)
      .gesture(
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpace))
          .onChanged { drag.changed($0.translation) }
          .onEnded { _ in drag.ended() }
      )
      .accessibilityLabel("Move \(title)")
  }

  private var actionsMenu: some View {
    Menu {
      Button(action: actions.returnToWorkspace) {
        Label("Return to Workspace", systemImage: "pip.exit")
          .labelStyle(.titleAndIcon)
      }
      Divider()
      PaneMenuItems(pane: pane, sessionStore: sessionStore) {
        renameText = title
        showingRename = true
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
