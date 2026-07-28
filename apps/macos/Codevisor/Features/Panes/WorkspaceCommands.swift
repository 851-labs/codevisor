import SwiftUI
import CodevisorCore

struct WorkspaceLayoutActions: Equatable {
    let workspaceId: UUID
    let newTab: @MainActor () -> Void
    let closeSplit: @MainActor () -> Void
    let closeTab: @MainActor () -> Void
    let previousTab: @MainActor () -> Void
    let nextTab: @MainActor () -> Void
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

struct WorkspaceLayoutCommands: Commands {
    @FocusedValue(\.workspaceLayoutActions) private var actions

    var body: some Commands {
        CommandMenu("Tabs & Splits") {
            ShortcutButton(.newTab) { actions?.newTab() }
                .disabled(actions == nil)

            ShortcutButton(.closeSplit) { actions?.closeSplit() }
                .disabled(actions == nil)
            ShortcutButton(.closeTab) { actions?.closeTab() }
                .disabled(actions == nil)

            Divider()

            ShortcutButton(.previousTab) { actions?.previousTab() }
                .disabled(actions == nil)
            ShortcutButton(.nextTab) { actions?.nextTab() }
                .disabled(actions == nil)

            Divider()

            ShortcutButton(.previousSplit) { actions?.previousSplit() }
                .disabled(actions == nil)
            ShortcutButton(.nextSplit) { actions?.nextSplit() }
                .disabled(actions == nil)

            Divider()

            ShortcutButton(.splitLeft) { actions?.split(.leading) }
                .disabled(actions == nil)
            ShortcutButton(.splitRight) { actions?.split(.trailing) }
                .disabled(actions == nil)
            ShortcutButton(.splitUp) { actions?.split(.top) }
                .disabled(actions == nil)
            ShortcutButton(.splitDown) { actions?.split(.bottom) }
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
    }
}
