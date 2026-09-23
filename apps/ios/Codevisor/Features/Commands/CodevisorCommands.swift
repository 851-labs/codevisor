import SwiftUI

/// Home's window-level actions, published by the focused scene's Home.
struct HomeCommandActions: Equatable {
  /// Distinguishes publishers so the menu bar refreshes when availability changes.
  var canCreateChat: Bool
  var hasSidebar: Bool
  let newChat: @MainActor () -> Void
  let openSettings: @MainActor () -> Void
  let toggleSidebar: @MainActor () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canCreateChat == rhs.canCreateChat && lhs.hasSidebar == rhs.hasSidebar
  }
}

/// The open workspace's tab actions, published by the focused
/// scene's workspace screen. Nil while no workspace is open (New Chat, the
/// phone's workspace list), which dims every item that needs one.
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

/// The iPad menu bar (and the hardware-keyboard shortcuts it lists on
/// iPhone too). Shortcuts match the macOS app's defaults so the same muscle
/// memory works on every device. Unavailable items stay visible but dimmed,
/// as the HIG asks for the menu bar.
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

    // Replaces the system's item, which opens the Settings app on the
    // same shortcut; Codevisor's settings live in the app, as on macOS.
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
