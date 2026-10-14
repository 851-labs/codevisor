import SwiftUI

struct HomeCommandActions: Equatable {
  var canCreateChat: Bool
  var hasSidebar: Bool
  let newChat: @MainActor () -> Void
  let openSettings: @MainActor () -> Void
  let toggleSidebar: @MainActor () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canCreateChat == rhs.canCreateChat && lhs.hasSidebar == rhs.hasSidebar
  }
}

struct WorkspaceCommandActions: Equatable {
  var workspaceId: UUID?
  var paneCount: Int
  let newTab: @MainActor () -> Void
  let closeTab: @MainActor () -> Void
  let selectTab: @MainActor (_ offset: Int) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.workspaceId == rhs.workspaceId && lhs.paneCount == rhs.paneCount
  }
}

extension FocusedValues {
  @Entry var homeCommandActions: HomeCommandActions?
  @Entry var workspaceCommandActions: WorkspaceCommandActions?
}

struct CodevisorCommands: Commands {
  @FocusedValue(\.homeCommandActions) private var home
  @FocusedValue(\.workspaceCommandActions) private var workspace

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Chat") { home?.newChat() }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(home?.canCreateChat != true)
      Button("New Tab") { workspace?.newTab() }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(workspace == nil)
      Divider()
      Button("Close Tab") { workspace?.closeTab() }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(workspace == nil)
    }

    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { home?.openSettings() }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(home == nil)
    }

    CommandGroup(before: .toolbar) {
      Button("Toggle Sidebar") { home?.toggleSidebar() }
        .keyboardShortcut("s", modifiers: [.command, .control])
        .disabled(home?.hasSidebar != true)
      Divider()
    }

    CommandMenu("Tabs") {
      Button("Previous Tab") { workspace?.selectTab(-1) }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled((workspace?.paneCount ?? 0) < 2)
      Button("Next Tab") { workspace?.selectTab(1) }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled((workspace?.paneCount ?? 0) < 2)
    }
  }
}
