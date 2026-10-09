import CodevisorCore
import CodevisorUI
import SwiftUI

/// The tab overview's state: nil while it's down.
enum WorkspaceTabOverview: Equatable {
  /// A tab's picture is shrinking from full size into its tile.
  case opening(UUID)
  case open
  /// A tile's picture is growing back to full size.
  case closing(UUID)
}

/// Where the active tab sits on screen. Kept out of observed state: the
/// keyboard moves it on every frame, and nothing redraws for it; only the
/// overview's snapshot and zoom read it.
final class WorkspacePaneFrame {
  var frame: CGRect = .zero
}

// MARK: - Tab overview

extension WorkspaceScreen {
  /// The workspace's tabs as the overview lists them, in the shared order.
  var overviewTabs: [HomeSidebarTabRow] {
    resolvedWorkspace.map { HomeSidebarSectionBuilder(environment: environment).tabRows(for: $0) } ?? []
  }

  private var overviewZoom: Animation? {
    accessibilityReduceMotion ? nil : .smooth(duration: 0.4)
  }

  /// The grid over the workspace's pane, while the overview is up.
  @ViewBuilder
  var tabOverviewLayer: some View {
    if let phase = tabOverview, let workspace = resolvedWorkspace {
      let frame = paneFrame.frame.size
      WorkspaceTabGrid(
        tabs: overviewTabs,
        serverId: workspace.serverId,
        selectedId: panes.selectedPaneId,
        homeChatId: environment.navigationStore.homeChatId(of: workspace),
        aspectRatio: frame.height > 0 ? frame.width / frame.height : 0.6,
        phase: phase,
        zoom: overviewZoom,
        onSettled: {
          if case .closing = tabOverview { tabOverview = nil } else { tabOverview = .open }
        },
        onSelect: { openFromOverview($0) },
        onClose: { id in panes.panes.first { $0.id == id }.map { closeFromOverview($0) } },
        onCloseOthers: { closeOthers(keeping: $0, in: workspace) },
        onReorder: { reorderTabs($0, in: workspace) },
        onNewTab: {
          addTab()
          if let id = panes.selectedPaneId { openFromOverview(id) }
        },
        onDone: { panes.selectedPaneId.map { openFromOverview($0) } }
      )
    }
  }

  /// The nav bar's tabs button, Safari's: zooms out to the overview, and
  /// back into the current tab when it's up.
  var tabsButton: some View {
    let count = overviewTabs.count
    return Button(action: toggleTabOverview) {
      Label("Tabs", systemImage: "square.on.square")
    }
    .accessibilityValue(count == 1 ? "1 tab" : "\(count) tabs")
  }

  /// Shrinks the active tab into its tile.
  func showTabOverview() {
    guard tabOverview == nil, let pane = activePane else { return }
    // The grid mounts under a full-size picture of the tab, identical to
    // the pane it covers; the picture then settles into its tile.
    PaneSnapshotCache.shared.capture(paneId: pane.id, frame: paneFrame.frame)
    tabOverview = .opening(pane.id)
  }

  /// Grows a tile back to full size and shows its tab.
  func openFromOverview(_ paneId: UUID) {
    guard tabOverview == .open else { return }
    if let pane = panes.panes.first(where: { $0.id == paneId }) { select(pane) }
    tabOverview = .closing(paneId)
  }

  func toggleTabOverview() {
    if tabOverview == nil {
      showTabOverview()
    } else if let selected = panes.selectedPaneId {
      openFromOverview(selected)
    }
  }

  private func closeFromOverview(_ pane: PaneDescriptorState) {
    withAnimation(Motion.listReflow(reduceMotion: accessibilityReduceMotion)) { close(pane) }
  }

  private func closeOthers(keeping paneId: UUID, in workspace: Workspace) {
    let home = environment.navigationStore.homeChatId(of: workspace)
    for pane in panes.panes where pane.id != paneId && (pane.chatSessionId == nil || pane.chatSessionId != home) {
      closeFromOverview(pane)
    }
  }

  /// Publishes the tabs' new order to every device. Panes of one split tab
  /// move together, at the first of them; subagents' tab groups keep their
  /// places among the tabs.
  private func reorderTabs(_ paneIds: [UUID], in workspace: Workspace) {
    let tabOfPane = Dictionary(
      overviewTabs.compactMap { row in row.tabId.map { (row.id, $0) } }, uniquingKeysWith: { first, _ in first })
    var seen: Set<UUID> = []
    let tabIds = paneIds.compactMap { tabOfPane[$0] }.filter { seen.insert($0).inserted }
    let navigation = environment.navigationStore
    let strip = navigation.tabStrip(for: workspace)
    let tabsById = Dictionary(
      strip.compactMap { entry -> (UUID, WorkspaceTab)? in
        if case let .tab(tab) = entry { (tab.id, tab) } else { nil }
      }, uniquingKeysWith: { first, _ in first })
    var reordered = tabIds.compactMap { tabsById[$0] }[...]
    let entries = strip.map { entry -> TabStripEntry in
      guard case .tab = entry, let next = reordered.popFirst() else { return entry }
      return .tab(next)
    }
    var state = panes
    state.panes =
      paneIds.compactMap { id in panes.panes.first { $0.id == id } }
      + panes.panes.filter { !paneIds.contains($0.id) }
    withAnimation(Motion.listReflow(reduceMotion: accessibilityReduceMotion)) { paneBinding.wrappedValue = state }
    navigation.publishTabStripOrder(of: workspace, entries: entries)
  }
}
