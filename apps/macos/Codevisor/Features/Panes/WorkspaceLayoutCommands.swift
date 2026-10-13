import SwiftUI
import CodevisorCore

struct WorkspaceLayoutActions: Equatable {
  let workspaceId: UUID
  let newTab: @MainActor () -> Void
  let closeSplit: @MainActor () -> Void
  let closeTab: @MainActor () -> Void
  let reopenClosedPane: @MainActor () -> Void
  let previousTab: @MainActor () -> Void
  let nextTab: @MainActor () -> Void
  let previousTabInWorkspace: @MainActor () -> Void
  let nextTabInWorkspace: @MainActor () -> Void
  let previousSplit: @MainActor () -> Void
  let nextSplit: @MainActor () -> Void
  let split: @MainActor (SplitEdge) -> Void
  let focus: @MainActor (SplitEdge) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workspaceId == rhs.workspaceId
  }
}

private struct WorkspaceLayoutActionsKey: FocusedValueKey {
  typealias Value = WorkspaceLayoutActions
}

extension FocusedValues {
  var workspaceLayoutActions: WorkspaceLayoutActions? {
    get { self[WorkspaceLayoutActionsKey.self] }
    set { self[WorkspaceLayoutActionsKey.self] = newValue }
  }
}

/// The workspace's split layout under View, and tab cycling under Window,
/// where Mac apps keep them. The tab items that create and close things live
/// in File, alongside New Chat and Close (see `NewTabMenuItem`).
struct WorkspaceLayoutCommands: Commands {
  @FocusedValue(\.workspaceLayoutActions) private var actions
  @FocusedValue(\.sidebarActions) private var sidebarActions

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Menu("Split") {
        ShortcutButton(.splitLeft) { actions?.split(.leading) }
          .disabled(actions == nil)
        ShortcutButton(.splitRight) { actions?.split(.trailing) }
          .disabled(actions == nil)
        ShortcutButton(.splitUp) { actions?.split(.top) }
          .disabled(actions == nil)
        ShortcutButton(.splitDown) { actions?.split(.bottom) }
          .disabled(actions == nil)
      }

      Menu("Focus Split") {
        ShortcutButton(.previousSplit) { actions?.previousSplit() }
          .disabled(actions == nil)
        ShortcutButton(.nextSplit) { actions?.nextSplit() }
          .disabled(actions == nil)

        Divider()

        ShortcutButton(.focusSplitLeft) { actions?.focus(.leading) }
          .disabled(actions == nil)
        ShortcutButton(.focusSplitRight) { actions?.focus(.trailing) }
          .disabled(actions == nil)
        ShortcutButton(.focusSplitAbove) { actions?.focus(.top) }
          .disabled(actions == nil)
        ShortcutButton(.focusSplitBelow) { actions?.focus(.bottom) }
          .disabled(actions == nil)
      }

      Divider()
    }

    CommandGroup(before: .windowArrangement) {
      // The sidebar owns the order across workspaces, so these work from
      // the New Chat page too.
      ShortcutButton(.previousTab) { stepTab(-1) }
        .disabled(actions == nil && sidebarActions == nil)
      ShortcutButton(.nextTab) { stepTab(1) }
        .disabled(actions == nil && sidebarActions == nil)
      // The refreshed sidebar's own commands; absent rather than disabled
      // without it, so their keys stay free for split focus.
      if FeatureFlag.sidebarRefresh.isEnabled {
        ShortcutButton(.previousTabInWorkspace) { actions?.previousTabInWorkspace() }
          .disabled(actions == nil)
        ShortcutButton(.nextTabInWorkspace) { actions?.nextTabInWorkspace() }
          .disabled(actions == nil)

        Divider()

        ShortcutButton(.previousWorkspace) { sidebarActions?.stepWorkspace?(-1) }
          .disabled(sidebarActions?.stepWorkspace == nil)
        ShortcutButton(.nextWorkspace) { sidebarActions?.stepWorkspace?(1) }
          .disabled(sidebarActions?.stepWorkspace == nil)
      }
    }
  }

  private func stepTab(_ offset: Int) {
    if let actions {
      if offset < 0 { actions.previousTab() } else { actions.nextTab() }
    } else {
      // The standalone New Chat page has no tabs; it steps the sidebar
      // (workspaces in the refresh, tab rows in the classic sidebar).
      if let stepWorkspace = sidebarActions?.stepWorkspace {
        stepWorkspace(offset)
      } else {
        sidebarActions?.stepTab?(offset)
      }
    }
  }
}

/// File > New Tab.
struct NewTabMenuItem: View {
  @FocusedValue(\.workspaceLayoutActions) private var actions

  var body: some View {
    ShortcutButton(.newTab) { actions?.newTab() }
      .disabled(actions == nil)
  }
}

/// File > Close Tab and Reopen Closed Pane. Close Split is File > Close
/// itself (see `CloseWindowMenuItem`).
struct CloseTabMenuItems: View {
  @FocusedValue(\.workspaceLayoutActions) private var actions

  var body: some View {
    ShortcutButton(.closeTab) { actions?.closeTab() }
      .disabled(actions == nil)
    ShortcutButton(.reopenClosedPane) { actions?.reopenClosedPane() }
      .disabled(actions == nil)
  }
}
