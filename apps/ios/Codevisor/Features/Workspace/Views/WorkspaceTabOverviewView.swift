import CodevisorCore
import CodevisorUI
import SwiftUI

/// What the tab overview asks its workspace screen to do with the agent's
/// own tabs.
struct WorkspaceTabOverviewActions {
  var select: (UUID) -> Void
  var close: (UUID) -> Void
  var closeOthers: (UUID) -> Void
  var reorder: ([UUID]) -> Void
  var newTab: () -> Void
  /// Zooms back into the current tab.
  var done: () -> Void
  /// Takes the overview down at once, as leaving for a subagent does.
  var dismiss: () -> Void
}

/// An agent's tab overview: its own tabs, then one page per subagent with a
/// workspace of its own, as Safari's tab groups. Swipe between the pages or
/// pick one in the bottom bar's pill; hold a subagent's segment for its
/// actions. Opening a subagent's tab shows its workspace in this one's place.
struct WorkspaceTabOverviewView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.showWorkspaceRoute) private var showWorkspaceRoute

  let workspace: Workspace
  let tabs: [HomeSidebarTabRow]
  let selectedId: UUID?
  let aspectRatio: CGFloat
  let phase: WorkspaceTabOverview
  let zoom: Animation?
  let onSettled: () -> Void
  let actions: WorkspaceTabOverviewActions

  /// The page showing: the agent's workspace or a subagent's.
  @State private var page: UUID?
  @State private var isZoomedIn = true

  private var navigation: NavigationStore { environment.navigationStore }

  private var groups: [TabStripGroup] {
    navigation.tabStrip(for: workspace).compactMap { entry in
      if case let .group(group) = entry { group } else { nil }
    }
  }

  private var isOwnPage: Bool { (page ?? workspace.id) == workspace.id }

  var body: some View {
    let groups = groups
    TabView(selection: Binding(get: { page ?? workspace.id }, set: { page = $0 })) {
      ownGrid.tag(workspace.id)
      ForEach(groups, id: \.workspaceId) { group in
        if let child = environment.workspaces.workspace(id: group.workspaceId) {
          childGrid(child).tag(child.id)
        }
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    // Paging only between settled grids; a zoom keeps its page.
    .scrollDisabled(phase != .open)
    .background(Color(.systemGroupedBackground))
    .overlay(alignment: .bottom) {
      bottomBar(groups)
        .opacity(isZoomedIn ? 0 : 1)
    }
  }

  private var ownGrid: some View {
    WorkspaceTabGrid(
      tabs: tabs, serverId: workspace.serverId, selectedId: selectedId,
      homeChatId: navigation.homeChatId(of: workspace), aspectRatio: aspectRatio,
      phase: phase, zoom: zoom, onSettled: onSettled,
      onSelect: actions.select, onClose: actions.close, onCloseOthers: actions.closeOthers,
      onReorder: actions.reorder, isZoomedIn: $isZoomedIn)
  }

  private func childGrid(_ child: Workspace) -> some View {
    let home = navigation.homeChatId(of: child)
    let tabs = HomeSidebarSectionBuilder(environment: environment).tabRows(for: child)
    return WorkspaceTabGrid(
      tabs: tabs, serverId: child.serverId, selectedId: nil, homeChatId: home, aspectRatio: aspectRatio,
      phase: .open, zoom: nil, onSettled: {},
      onSelect: { paneId in open(child, chat: tabs.first { $0.id == paneId }?.chatSessionId, pane: paneId) },
      onClose: { close($0, in: child) },
      onCloseOthers: { keep in
        for tab in tabs where tab.id != keep && (tab.chatSessionId == nil || tab.chatSessionId != home) {
          close(tab.id, in: child)
        }
      },
      onReorder: nil, isZoomedIn: .constant(false))
  }

  private func bottomBar(_ groups: [TabStripGroup]) -> some View {
    HStack(spacing: 12) {
      Button("New Tab", systemImage: "plus", action: actions.newTab)
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(!isOwnPage)
      Spacer(minLength: 0)
      if groups.isEmpty {
        Text(countTitle).font(.headline)
      } else {
        groupPill(groups)
      }
      Spacer(minLength: 0)
      Button("Done", action: isOwnPage ? actions.done : actions.dismiss)
        .buttonStyle(.glass)
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 4)
  }

  private var countTitle: String {
    tabs.count == 1 ? "1 Tab" : "\(tabs.count) Tabs"
  }

  /// One segment per page: the agent's tabs, then each subagent with its
  /// status.
  private func groupPill(_ groups: [TabStripGroup]) -> some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 2) {
          segment(id: workspace.id, title: countTitle, status: nil)
          ForEach(groups, id: \.workspaceId) { group in
            segment(id: group.workspaceId, title: group.title, status: group.status)
              .contextMenu { groupMenu(group) }
          }
        }
        .padding(3)
      }
      .scrollIndicators(.hidden)
      .onChange(of: page) { _, page in
        withAnimation(.smooth) { proxy.scrollTo(page ?? workspace.id, anchor: .center) }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .glassEffect(.regular, in: .capsule)
  }

  private func segment(id: UUID, title: String, status: AgentStatus?) -> some View {
    let isSelected = (page ?? workspace.id) == id
    return Button {
      withAnimation(.smooth) { page = id }
    } label: {
      HStack(spacing: 6) {
        if let status {
          HomeStatusIndicator(status: HomeSessionStatus(status))
            .frame(width: 10, height: 10)
        }
        Text(title)
          .font(.subheadline.weight(isSelected ? .semibold : .regular))
          .lineLimit(1)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background {
        if isSelected { Capsule().fill(.fill.secondary) }
      }
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .id(id)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private func groupMenu(_ group: TabStripGroup) -> some View {
    if let child = environment.workspaces.workspace(id: group.workspaceId) {
      Button("Open Chat", systemImage: "bubble.left") {
        open(child, chat: navigation.homeChatId(of: child), pane: nil)
      }
      Button("Move to Sidebar", systemImage: "sidebar.left") {
        navigation.enqueue(
          .updateWorkspaceHierarchy(workspaceId: child.id, change: .owner(nil)), machineId: child.serverId)
      }
      Button("Archive", systemImage: "archivebox", role: .destructive) {
        environment.archiveWorkspace(child)
      }
    }
  }

  /// Shows the subagent's workspace on the tab: its chat, or the pane.
  private func open(_ child: Workspace, chat: UUID?, pane: UUID?) {
    actions.dismiss()
    showWorkspaceRoute(
      .workspace(
        serverId: child.serverId, workspaceId: child.id, anchorSessionId: chat ?? navigation.homeChatId(of: child),
        preferredChatSessionId: chat, preferredPaneId: chat == nil ? pane : nil))
  }

  private func close(_ paneId: UUID, in child: Workspace) {
    environment.workspaceSync.deletePane(
      id: paneId, workspaceId: child.id, client: environment.machines.client(for: child.serverId))
  }
}
