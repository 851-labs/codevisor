import CodevisorCore
import CodevisorUI
import SwiftUI

struct CommandPaletteCatalog {
  var sidebar: SidebarActions?
  var botList: BotListActions?
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
    guard let sidebar else { return botListCommands }

    return [
      CommandPaletteItem(.newChat, systemImage: "square.and.pencil") {
        sidebar.newChat()
        composerFocus?.focus()
      },
      CommandPaletteItem(.newProject, systemImage: "folder.badge.plus", perform: sidebar.newProject),
    ]
  }

  private var botListCommands: [CommandPaletteItem] {
    guard let botList else { return [] }

    let newProject = CommandPaletteItem(.newProject, systemImage: "folder.badge.plus", perform: botList.newProject)
    guard let newBot = botList.newBot else { return [newProject] }
    let newBotItem = CommandPaletteItem(
      id: "newBot", title: "New Bot", icon: .symbol("square.and.pencil"),
      shortcut: ShortcutCatalog.combo(for: .newChat)?.keyboardShortcut, perform: newBot)
    return [newBotItem, newProject]
  }

  private var activeWorkspaceSections: [CommandPaletteSection] {
    guard let workspace = sidebar?.activeWorkspace?() else { return [] }

    return [
      CommandPaletteSection(
        id: "activeWorkspace", title: workspace.name, items: activeWorkspaceCommands(workspace))
    ]
  }

  private func activeWorkspaceCommands(_ workspace: ActiveWorkspaceActions) -> [CommandPaletteItem] {
    let pinTitle = workspace.isPinned ? "Unpin Workspace" : "Pin Workspace"
    return [
      CommandPaletteItem(
        id: "togglePin", title: pinTitle, icon: .symbol(workspace.isPinned ? "pin.slash" : "pin"),
        perform: workspace.togglePin),
      CommandPaletteItem("Rename Workspace…", systemImage: "pencil", perform: workspace.rename),
    ] + forkCommands(workspace) + [
      CommandPaletteItem(.archiveWorkspace, systemImage: "archivebox", perform: workspace.archive)
    ]
  }

  private func forkCommands(_ workspace: ActiveWorkspaceActions) -> [CommandPaletteItem] {
    guard let fork = workspace.fork else { return [] }
    return [CommandPaletteItem("Fork Workspace", systemImage: "arrow.triangle.branch", perform: fork)]
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

    let title = sidebarVisibility.isVisible ? "Hide Sidebar" : "Show Sidebar"
    return [
      CommandPaletteItem(
        id: "toggleSidebar", title: title, icon: .symbol("sidebar.leading"), searchTerms: ["Toggle Sidebar"]
      ) {
        sidebarVisibility.setVisible(!sidebarVisibility.isVisible)
      }
    ]
  }

  private var inspectorToggleCommands: [CommandPaletteItem] {
    guard let inspector else { return [] }

    let title = inspector.isVisible ? "Hide Inspector" : "Show Inspector"
    return [
      CommandPaletteItem(
        id: "toggleInspector", title: title, icon: .symbol("sidebar.trailing"), searchTerms: ["Toggle Inspector"],
        perform: inspector.toggle)
    ]
  }

  private var inspectorTabCommands: [CommandPaletteItem] {
    guard let inspector else { return [] }

    return inspector.tabs.map { tab in
      CommandPaletteItem(
        id: "inspector:\(tab.rawValue)", title: tab.title,
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
