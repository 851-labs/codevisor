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
            Button("New Tab") { actions?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions == nil)

            Button("Close Split") { actions?.closeSplit() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(actions == nil)
            Button("Close Tab") { actions?.closeTab() }
                .disabled(actions == nil)

            Divider()

            Button("Previous Tab") { actions?.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Next Tab") { actions?.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(actions == nil)

            Divider()

            Button("Previous Split") { actions?.previousSplit() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions == nil)
            Button("Next Split") { actions?.nextSplit() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions == nil)

            Divider()

            Button("Split Left") { actions?.split(.leading) }
                .disabled(actions == nil)
            Button("Split Right") { actions?.split(.trailing) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(actions == nil)
            Button("Split Up") { actions?.split(.top) }
                .disabled(actions == nil)
            Button("Split Down") { actions?.split(.bottom) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(actions == nil)

            Divider()

            Button("Focus Split Left") { actions?.focus(.leading) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Focus Split Right") { actions?.focus(.trailing) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Focus Split Above") { actions?.focus(.top) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Focus Split Below") { actions?.focus(.bottom) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(actions == nil)
        }
    }
}
