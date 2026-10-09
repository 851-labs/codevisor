import CodevisorCore
import CodevisorUI
import SwiftUI

/// What the tab overview asks its workspace screen to do with the agent's
/// tabs.
struct WorkspaceTabOverviewActions {
  var select: (UUID) -> Void
  var close: (UUID) -> Void
  var closeOthers: (UUID) -> Void
  var reorder: ([UUID]) -> Void
  var newTab: () -> Void
  /// Zooms back into the current tab.
  var done: () -> Void
}

/// An agent's tab overview: the grid of its tabs, with New Tab, the count
/// and Done floating along the bottom. Agents it owns aren't here; they
/// nest under it in the agent list.
struct WorkspaceTabOverviewView: View {
  @Environment(AppEnvironment.self) private var environment

  let workspace: Workspace
  let tabs: [HomeSidebarTabRow]
  let selectedId: UUID?
  let aspectRatio: CGFloat
  let phase: WorkspaceTabOverview
  let zoom: Animation?
  let onSettled: () -> Void
  let actions: WorkspaceTabOverviewActions

  @State private var isZoomedIn = true

  var body: some View {
    WorkspaceTabGrid(
      tabs: tabs, serverId: workspace.serverId, selectedId: selectedId,
      homeChatId: environment.navigationStore.homeChatId(of: workspace), aspectRatio: aspectRatio,
      phase: phase, zoom: zoom, onSettled: onSettled,
      onSelect: actions.select, onClose: actions.close, onCloseOthers: actions.closeOthers,
      onReorder: actions.reorder, isZoomedIn: $isZoomedIn
    )
    .overlay(alignment: .bottom) {
      bottomBar.opacity(isZoomedIn ? 0 : 1)
    }
  }

  private var bottomBar: some View {
    HStack(spacing: 12) {
      Button("New Tab", systemImage: "plus", action: actions.newTab)
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
      Spacer(minLength: 0)
      Text(tabs.count == 1 ? "1 Tab" : "\(tabs.count) Tabs").font(.headline)
      Spacer(minLength: 0)
      Button("Done", action: actions.done)
        .buttonStyle(.glass)
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 4)
  }
}
