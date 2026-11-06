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
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        leadingToolbar
        if source?.replacesTitle == true {
          toolbar(.principal)
            .layoutPriority(1)
          dragArea { Color.clear.frame(minWidth: Self.minimumDragWidth, maxWidth: .infinity) }
        } else {
          dragArea { titleText }
        }
        if source?.hasTrailingControls == true {
          FloatingPaneTrailingToolbar { toolbar(.trailing) }
        }
        FloatingPaneGlassGroup { actionsMenu }
        FloatingPaneGlassGroup { closeButton }
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 40)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .modifier(
      PaneRenameAlert(kind: pane?.kind, isPresented: $showingRename, text: $renameText, onRename: actions.rename))
  }

  @ViewBuilder
  private var leadingToolbar: some View {
    if source?.hasLeadingControls == true {
      FloatingPaneGlassGroup { toolbar(.leading) }
    }
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
      .padding(.leading, source?.hasLeadingControls == true ? 0 : 6)
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
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Floating pane actions")
    .accessibilityLabel("Floating pane actions")
  }

  private var closeButton: some View {
    Button(action: actions.close) {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .semibold))
    }
    .help("Close")
    .accessibilityLabel("Close \(title)")
  }
}
