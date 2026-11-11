import CodevisorCore
import CodevisorUI
import SwiftUI

struct CommandPaletteCatalog {
  var sidebar: SidebarActions?
  var botList: BotListActions?
  var root: RootSidebarActions?
  var destinations: PaletteDestinations?
  var composerFocus: NewChatComposerFocus?
  var layout: WorkspaceLayoutActions?
  var file: FilePaneModel?
  var chatFind: TranscriptFindModel?
  var browser: ChromiumBrowserModel?
  var debugOverlay: DebugOverlayToggleAction?
  var sidebarVisibility: SidebarVisibilityToggle?
  var inspector: WorkspaceInspectorActions?
  var developerMode = false
  let openSettings: @MainActor () -> Void

  private static let splitEdges: [SplitEdge] = [.leading, .trailing, .top, .bottom]

  var sections: [CommandPaletteSection] {
    let sections =
      activeWorkspaceSections
      + [
        CommandPaletteSection(title: "General", items: generalCommands + appCommands),
        CommandPaletteSection(title: "View", items: sidebarCommands + inspectorToggleCommands),
        CommandPaletteSection(title: "Inspector", items: inspectorTabCommands),
        CommandPaletteSection(title: "Find", items: findCommands),
        CommandPaletteSection(title: "Browser", items: browserCommands),
        CommandPaletteSection(title: "Tabs & Splits", items: layoutCommands),
        CommandPaletteSection(title: "Developer", items: developerCommands),
        CommandPaletteSection(id: "bots", title: "Go to Bot", items: destinations?.bots() ?? []),
        CommandPaletteSection(id: "workspaces", title: "Go to Workspace", items: destinations?.workspaces() ?? []),
      ]
    return sections.filter { !$0.items.isEmpty }
  }

  private var generalCommands: [CommandPaletteItem] {
    guard let root else { return [] }

    return [newChatCommand(root)] + newBotCommands(root) + newProjectCommands
  }

  private func newChatCommand(_ root: RootSidebarActions) -> CommandPaletteItem {
    CommandPaletteItem(.newChat, systemImage: "square.and.pencil") {
      root.newChat()
      composerFocus?.focus()
    }
  }

  private func newBotCommands(_ root: RootSidebarActions) -> [CommandPaletteItem] {
    guard let newBot = root.newBot else { return [] }

    return [CommandPaletteItem(.newBot, icon: .codevisorSymbol(.mascotBadgePlus), perform: newBot)]
  }

  private var newProjectCommands: [CommandPaletteItem] {
    guard let newProject = sidebar?.newProject ?? botList?.newProject else { return [] }

    return [CommandPaletteItem(.newProject, systemImage: "folder.badge.plus", perform: newProject)]
  }

  private var activeWorkspaceSections: [CommandPaletteSection] {
    guard let workspace = sidebar?.activeWorkspace?() else { return [] }

    return [
      CommandPaletteSection(
        id: "activeWorkspace", title: workspace.name, items: activeWorkspaceCommands(workspace))
    ]
  }

  private func activeWorkspaceCommands(_ workspace: ActiveWorkspaceActions) -> [CommandPaletteItem] {
    pinCommands(workspace.pin) + [
      CommandPaletteItem("Rename Workspace…", systemImage: "pencil", perform: workspace.rename),
      CommandPaletteItem(.archiveWorkspace, systemImage: "archivebox", perform: workspace.archive),
    ]
  }

  private func pinCommands(_ pin: WorkspacePin?) -> [CommandPaletteItem] {
    guard let pin else { return [] }

    return [
      CommandPaletteItem(
        id: "togglePin", title: "\(pin.title) Workspace", icon: .symbol(pin.systemImage), perform: pin.toggle)
    ]
  }

  private var layoutCommands: [CommandPaletteItem] {
    guard let layout else { return [] }

    return [
      CommandPaletteItem(.newTab, systemImage: "plus.square.on.square", perform: layout.newTab),
      CommandPaletteItem(.closeTab, systemImage: "xmark.square", perform: layout.closeTab),
      CommandPaletteItem(.closeSplit, systemImage: "xmark.rectangle", perform: layout.closeSplit),
      CommandPaletteItem(.reopenClosedPane, systemImage: "arrow.uturn.backward", perform: layout.reopenClosedPane),
      CommandPaletteItem(
        .previousTabInWorkspace, systemImage: "arrow.left.square", perform: layout.previousTabInWorkspace),
      CommandPaletteItem(.nextTabInWorkspace, systemImage: "arrow.right.square", perform: layout.nextTabInWorkspace),
      CommandPaletteItem(
        .previousSplit, systemImage: "rectangle.lefthalf.inset.filled.arrow.left", perform: layout.previousSplit),
      CommandPaletteItem(
        .nextSplit, systemImage: "rectangle.righthalf.inset.filled.arrow.right", perform: layout.nextSplit),
    ]
      + Self.splitEdges.map { edge in
        CommandPaletteItem(.split(towards: edge), systemImage: Self.splitSymbol(edge)) { layout.split(edge) }
      }
      + Self.splitEdges.map { edge in
        CommandPaletteItem(.focusSplit(towards: edge), systemImage: Self.focusSymbol(edge)) { layout.focus(edge) }
      }
  }

  private static func splitSymbol(_ edge: SplitEdge) -> String {
    switch edge {
    case .leading, .trailing: "rectangle.split.2x1"
    case .top, .bottom: "rectangle.split.1x2"
    }
  }

  private static func focusSymbol(_ edge: SplitEdge) -> String {
    switch edge {
    case .leading: "rectangle.lefthalf.inset.filled"
    case .trailing: "rectangle.righthalf.inset.filled"
    case .top: "rectangle.tophalf.inset.filled"
    case .bottom: "rectangle.bottomhalf.inset.filled"
    }
  }

  private var findCommands: [CommandPaletteItem] {
    if let file, file.isEditingText { return fileCommands(file) }
    guard let chatFind else { return [] }

    return [
      CommandPaletteItem(
        "Find in Chat…", systemImage: "magnifyingglass", shortcut: KeyboardShortcut("f"), perform: chatFind.present)
    ]
  }

  private func fileCommands(_ file: FilePaneModel) -> [CommandPaletteItem] {
    let find = CommandPaletteItem("Find in File…", systemImage: "magnifyingglass", shortcut: KeyboardShortcut("f")) {
      file.showsFind = true
      file.editor.preview = false
    }
    let goToLine = CommandPaletteItem(
      "Go to Line…", systemImage: "text.line.first.and.arrowtriangle.forward",
      shortcut: KeyboardShortcut("g", modifiers: .control)
    ) {
      file.showsGoToLine = true
    }
    guard file.canSave else { return [find, goToLine] }

    let save = CommandPaletteItem("Save", systemImage: "square.and.arrow.down", shortcut: KeyboardShortcut("s")) {
      Task { await file.document.save() }
    }
    return [save, find, goToLine]
  }

  private var browserCommands: [CommandPaletteItem] {
    guard let browser else { return [] }

    let page = [
      CommandPaletteItem(
        "Open Location", systemImage: "globe", shortcut: KeyboardShortcut("l"), perform: browser.address.focus),
      CommandPaletteItem(
        "Developer Tools", systemImage: "hammer", shortcut: KeyboardShortcut("i", modifiers: [.command, .option]),
        perform: browser.showDevTools),
      CommandPaletteItem("Reload Page", systemImage: "arrow.clockwise", shortcut: KeyboardShortcut("r")) {
        browser.reload()
      },
      CommandPaletteItem(
        "Reload Page Ignoring Cache", systemImage: "arrow.clockwise.circle",
        shortcut: KeyboardShortcut("r", modifiers: [.command, .shift])
      ) {
        browser.reload(ignoringCache: true)
      },
    ]
    return page + zoomCommands(browser)
  }

  private func zoomCommands(_ browser: ChromiumBrowserModel) -> [CommandPaletteItem] {
    let zoomIn = CommandPaletteItem(.browserZoomIn, systemImage: "plus.magnifyingglass") { browser.zoom(.zoomIn) }
    let zoomOut = CommandPaletteItem(.browserZoomOut, systemImage: "minus.magnifyingglass") { browser.zoom(.zoomOut) }
    let reset = CommandPaletteItem(.browserResetZoom, systemImage: "1.magnifyingglass") { browser.zoom(.reset) }
    return (browser.pageZoom.canZoomIn ? [zoomIn] : []) + (browser.pageZoom.canZoomOut ? [zoomOut] : [])
      + (browser.pageZoom.canReset ? [reset] : [])
  }

  private var sidebarCommands: [CommandPaletteItem] {
    guard let sidebarVisibility else { return [] }

    return [
      panelToggleCommand(
        .sidebar, isVisible: sidebarVisibility.isVisible, systemImage: "sidebar.leading",
        perform: sidebarVisibility.toggle)
    ]
  }

  private var inspectorToggleCommands: [CommandPaletteItem] {
    guard let inspector else { return [] }

    return [
      panelToggleCommand(
        .inspector, isVisible: inspector.isVisible, systemImage: "sidebar.trailing", perform: inspector.toggle)
    ]
  }

  private func panelToggleCommand(
    _ panel: PanelToggleShortcut, isVisible: Bool, systemImage: String, perform: @escaping @MainActor () -> Void
  ) -> CommandPaletteItem {
    CommandPaletteItem(
      id: panel.id.rawValue, title: panel.title(isVisible: isVisible), icon: .symbol(systemImage),
      shortcut: ShortcutCatalog.combo(for: panel.id)?.keyboardShortcut, searchTerms: [panel.searchTerm],
      perform: perform)
  }

  private var inspectorTabCommands: [CommandPaletteItem] {
    guard let inspector else { return [] }

    return inspector.tabs.map { tab in
      CommandPaletteItem(
        id: "inspector:\(tab.rawValue)", title: "Show \(tab.title)",
        icon: tab == .harness ? .harness(inspector.harnessId) : .symbol(tab.systemImage),
        searchTerms: ["Show \(tab.title) Inspector"]
      ) { inspector.show(tab) }
    }
  }

  private var developerCommands: [CommandPaletteItem] {
    guard developerMode, let debugOverlay else { return [] }

    let title = debugOverlay.isVisible ? "Hide Debug Overlay" : "Show Debug Overlay"
    return [
      CommandPaletteItem(
        id: ShortcutID.toggleDebugOverlay.rawValue, title: title, icon: .symbol("gauge.with.dots.needle.50percent"),
        searchTerms: [ShortcutCatalog.title(for: .toggleDebugOverlay)], perform: debugOverlay.toggle)
    ]
  }

  private var appCommands: [CommandPaletteItem] {
    let settings = CommandPaletteItem(
      id: "settings", title: "Settings…", icon: .symbol("gearshape"), shortcut: KeyboardShortcut(","),
      searchTerms: ["Preferences"], perform: openSettings)
    let updates = CommandPaletteItem("Check for Updates…", systemImage: "arrow.down.circle") {
      SettingsRouter.shared.showUpdates()
      openSettings()
    }
    return [settings, updates]
  }
}
