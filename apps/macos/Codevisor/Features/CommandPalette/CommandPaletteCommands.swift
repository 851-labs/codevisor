import AppKit
import CodevisorCore
import SwiftUI

struct CommandPaletteCommands: Commands {
  var body: some Commands {
    CommandGroup(before: .toolbar) {
      CommandPaletteMenuItem()
      Divider()
    }
  }
}

private struct CommandPaletteMenuItem: View {
  @FocusedValue(\.commandPalette) private var palette
  @FocusedValue(\.sidebarActions) private var sidebar
  @FocusedValue(\.botListActions) private var botList
  @FocusedValue(\.paletteDestinations) private var destinations
  @FocusedValue(\.newChatComposerFocus) private var composerFocus
  @FocusedValue(\.workspaceLayoutActions) private var layout
  @FocusedValue(\.filePane) private var file
  @FocusedValue(\.transcriptFind) private var chatFind
  @FocusedValue(\.browserPage) private var browser
  @FocusedValue(\.debugOverlayToggle) private var debugOverlay
  @FocusedValue(\.sidebarVisibility) private var sidebarVisibility
  @FocusedValue(\.workspaceInspector) private var inspector
  @Environment(\.openSettings) private var openSettings
  @ClientPreference(FeatureFlag.developerMode.preferenceKey, default: false) private var developerMode

  var body: some View {
    ShortcutButton(.commandPalette) { palette?.toggle(catalog.sections, in: NSApp.keyWindow) }
      .disabled(palette == nil)
  }

  private var catalog: CommandPaletteCatalog {
    CommandPaletteCatalog(
      sidebar: sidebar, botList: botList, destinations: destinations, composerFocus: composerFocus, layout: layout,
      file: file, chatFind: chatFind,
      browser: browser, debugOverlay: debugOverlay, sidebarVisibility: sidebarVisibility, inspector: inspector,
      developerMode: developerMode,
      openSettings: { openSettings() })
  }
}
