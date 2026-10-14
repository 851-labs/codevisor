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

  var workspaceTabCycling: WorkspaceTabCycling? {
    get { self[WorkspaceTabCyclingKey.self] }
    set { self[WorkspaceTabCyclingKey.self] = newValue }
  }
}

struct WorkspaceTabCycling: Equatable {
  let workspaceId: UUID
  let tabIds: [UUID]
  let previous: @MainActor () -> Void
  let next: @MainActor () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workspaceId == rhs.workspaceId && lhs.tabIds == rhs.tabIds
  }
}

private struct WorkspaceTabCyclingKey: FocusedValueKey {
  typealias Value = WorkspaceTabCycling
}

struct WorkspaceLayoutCommands: Commands {
  @FocusedValue(\.workspaceLayoutActions) private var actions
  @FocusedValue(\.workspaceTabCycling) private var tabCycling
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
      ShortcutButton(.previousTab) { stepTab(-1) }
        .disabled(actions == nil && sidebarActions == nil)
      ShortcutButton(.nextTab) { stepTab(1) }
        .disabled(actions == nil && sidebarActions == nil)
      if FeatureFlag.sidebarRefresh.isEnabled {
        ShortcutButton(.previousTabInWorkspace) {
          if let actions { actions.previousTabInWorkspace() } else { tabCycling?.previous() }
        }
        .disabled(actions == nil && tabCycling == nil)
        ShortcutButton(.nextTabInWorkspace) {
          if let actions { actions.nextTabInWorkspace() } else { tabCycling?.next() }
        }
        .disabled(actions == nil && tabCycling == nil)

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
      if let stepWorkspace = sidebarActions?.stepWorkspace {
        stepWorkspace(offset)
      } else {
        sidebarActions?.stepTab?(offset)
      }
    }
  }
}

struct NewTabMenuItem: View {
  @FocusedValue(\.workspaceLayoutActions) private var actions

  var body: some View {
    ShortcutButton(.newTab) { actions?.newTab() }
      .disabled(actions == nil)
  }
}

struct CloseTabMenuItems: View {
  @FocusedValue(\.workspaceLayoutActions) private var actions

  var body: some View {
    ShortcutButton(.closeTab) { actions?.closeTab() }
      .disabled(actions == nil)
    ShortcutButton(.reopenClosedPane) { actions?.reopenClosedPane() }
      .disabled(actions == nil)
  }
}
