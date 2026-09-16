import CodevisorClient
import CodevisorUI
import SwiftUI

private struct FilePaneKey: FocusedValueKey {
  typealias Value = FilePaneModel
}

/// Scene-scoped creation and navigation actions published by the sidebar (via
/// `.focusedSceneValue`) so menu commands drive the same code paths as
/// the sidebar's own rows. Absent during onboarding — the sidebar isn't on
/// screen — which leaves the menu items disabled.
struct SidebarActions: Equatable {
  let newChat: @MainActor () -> Void
  let newProject: @MainActor () -> Void
  let addRemoteMachine: @MainActor () -> Void
  let stepTab: @MainActor (Int) -> Void

  /// The closures capture stable references (bindings and the app
  /// environment), so any published instance is interchangeable.
  static func == (lhs: SidebarActions, rhs: SidebarActions) -> Bool { true }
}

private struct SidebarActionsKey: FocusedValueKey {
  typealias Value = SidebarActions
}

/// Published by the new-chat page so ⌘N moves first-responder focus into the
/// composer even when that page is already on screen (navigating to it covers
/// the other case: the composer grabs focus as it appears).
struct NewChatComposerFocus: Equatable {
  let focus: @MainActor () -> Void

  static func == (lhs: NewChatComposerFocus, rhs: NewChatComposerFocus) -> Bool { true }
}

private struct NewChatComposerFocusKey: FocusedValueKey {
  typealias Value = NewChatComposerFocus
}

extension FocusedValues {
  var filePane: FilePaneModel? {
    get { self[FilePaneKey.self] }
    set { self[FilePaneKey.self] = newValue }
  }

  var sidebarActions: SidebarActions? {
    get { self[SidebarActionsKey.self] }
    set { self[SidebarActionsKey.self] = newValue }
  }

  var newChatComposerFocus: NewChatComposerFocus? {
    get { self[NewChatComposerFocusKey.self] }
    set { self[NewChatComposerFocusKey.self] = newValue }
  }
}

/// The File > New items. Replaces the default "New Window" so ⌘N creates a
/// chat — the app's primary "new document" action.
struct FileCommands: Commands {
  @FocusedValue(\.filePane) private var file

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      NewChatMenuItem()
      NewProjectMenuItem()
    }
    CommandGroup(after: .newItem) {
      if let file {
        Button("Open File…") { file.showsExplorer = true }
          .keyboardShortcut("o", modifiers: .command)
      }
    }
    CommandGroup(replacing: .saveItem) {
      if let file, !file.isBrowsing {
        Button("Save") { Task { await file.document.save() } }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!file.canSave)
      }
    }
    CommandGroup(after: .textEditing) {
      if let file, !file.isBrowsing, file.document.snapshot?.content != nil {
        Button("Find in File…") {
          file.showsFind = true
          file.editor.preview = false
        }
        .keyboardShortcut("f", modifiers: .command)
        Button("Go to Line…") { file.showsGoToLine = true }
          .keyboardShortcut("g", modifiers: .control)
      }
    }
  }
}

private struct NewChatMenuItem: View {
  @FocusedValue(\.sidebarActions) private var actions
  @FocusedValue(\.newChatComposerFocus) private var composerFocus

  var body: some View {
    ShortcutButton(.newChat) {
      actions?.newChat()
      // Already on the new-chat page: navigation is a no-op, so move
      // focus into the composer directly.
      composerFocus?.focus()
    }
    .disabled(actions == nil)
  }
}

private struct NewProjectMenuItem: View {
  @FocusedValue(\.sidebarActions) private var actions

  var body: some View {
    ShortcutButton(.newProject) { actions?.newProject() }
      .disabled(actions == nil)
  }
}
