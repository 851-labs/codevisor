import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

private struct FilePaneKey: FocusedValueKey {
  typealias Value = FilePaneModel
}

struct SidebarActions: Equatable {
  let newChat: @MainActor () -> Void
  let newProject: @MainActor () -> Void
  var stepWorkspace: (@MainActor (Int) -> Void)? = nil
  var archiveWorkspace: (@MainActor () -> Void)? = nil
  var activeWorkspace: (@MainActor () -> ActiveWorkspaceActions?)? = nil

  static func == (lhs: SidebarActions, rhs: SidebarActions) -> Bool { true }
}

private struct SidebarActionsKey: FocusedValueKey {
  typealias Value = SidebarActions
}

struct NewChatComposerFocus: Equatable {
  let focus: @MainActor () -> Void

  static func == (lhs: NewChatComposerFocus, rhs: NewChatComposerFocus) -> Bool { true }
}

private struct NewChatComposerFocusKey: FocusedValueKey {
  typealias Value = NewChatComposerFocus
}

private struct TranscriptFindKey: FocusedValueKey {
  typealias Value = TranscriptFindModel
}

extension FocusedValues {
  var filePane: FilePaneModel? {
    get { self[FilePaneKey.self] }
    set { self[FilePaneKey.self] = newValue }
  }

  var transcriptFind: TranscriptFindModel? {
    get { self[TranscriptFindKey.self] }
    set { self[TranscriptFindKey.self] = newValue }
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

struct FileCommands: Commands {
  @FocusedValue(\.filePane) private var file
  @FocusedValue(\.transcriptFind) private var chatFind
  @FocusedValue(\.botListActions) private var botActions

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      if botActions != nil {
        NewBotMenuItem()
        NewProjectMenuItem()

        Divider()

        CloseWindowMenuItem()
      } else {
        NewChatMenuItem()
        NewProjectMenuItem()
        NewTabMenuItem()

        Divider()

        CloseWindowMenuItem()
        CloseTabMenuItems()
        ArchiveWorkspaceMenuItem()
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
      if let file, file.isEditingText {
        Button("Find in File…") {
          file.showsFind = true
          file.editor.preview = false
        }
        .keyboardShortcut("f", modifiers: .command)
        Button("Go to Line…") { file.showsGoToLine = true }
          .keyboardShortcut("g", modifiers: .control)
      } else if let chatFind {
        Button("Find in Chat…") { chatFind.present() }
          .keyboardShortcut("f", modifiers: .command)
        Button("Find Next") { chatFind.findNext() }
          .keyboardShortcut("g", modifiers: .command)
        Button("Find Previous") { chatFind.findPrevious() }
          .keyboardShortcut("g", modifiers: [.command, .shift])
      }
    }
  }
}

private struct CloseWindowMenuItem: View {
  @FocusedValue(\.workspaceLayoutActions) private var workspace

  var body: some View {
    Button(workspace == nil ? "Close" : ShortcutCatalog.definition(for: .closeSplit).title) {
      if let workspace {
        workspace.closeSplit()
      } else {
        NSApp.keyWindow?.performClose(nil)
      }
    }
    .keyboardShortcut("w", modifiers: .command)
  }
}

private struct NewChatMenuItem: View {
  @FocusedValue(\.sidebarActions) private var actions
  @FocusedValue(\.newChatComposerFocus) private var composerFocus

  var body: some View {
    ShortcutButton(.newChat) {
      actions?.newChat()
      composerFocus?.focus()
    }
    .disabled(actions == nil)
  }
}

private struct ArchiveWorkspaceMenuItem: View {
  @FocusedValue(\.sidebarActions) private var actions

  var body: some View {
    ShortcutButton(.archiveWorkspace) { actions?.archiveWorkspace?() }
      .disabled(actions?.archiveWorkspace == nil)
  }
}

private struct NewProjectMenuItem: View {
  @FocusedValue(\.sidebarActions) private var actions
  @FocusedValue(\.botListActions) private var botActions

  private var newProject: (@MainActor () -> Void)? {
    actions?.newProject ?? botActions?.newProject
  }

  var body: some View {
    ShortcutButton(.newProject) { newProject?() }
      .disabled(newProject == nil)
  }
}
