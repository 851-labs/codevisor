import CodevisorCore
import CodevisorUI
import SwiftUI

struct FloatingPaneHeader: View {
  let pane: PaneDescriptorState?
  let title: String
  let source: PaneToolbarSource?
  let coordinateSpace: String
  let actions: FloatingPaneActions
  let drag: FloatingPaneDrag

  @Environment(AppEnvironment.self) private var environment

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
      PaneHeaderToolbar(source: source, slot: slot)
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
      if let session = PaneMenuItems.chatSession(of: pane, in: environment.projectList) {
        ChatSessionUnreadMenuItem(session: session)
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
