import SwiftUI

enum ShortcutID: String, CaseIterable, Identifiable, Sendable {
  case newChat
  case newProject
  case archiveWorkspace

  case newTab
  case closeSplit
  case closeTab
  case reopenClosedPane
  case selectTab
  case previousTab
  case nextTab
  case previousTabInWorkspace
  case nextTabInWorkspace
  case previousWorkspace
  case nextWorkspace
  case previousSplit
  case nextSplit
  case splitLeft
  case splitRight
  case splitUp
  case splitDown
  case focusSplitLeft
  case focusSplitRight
  case focusSplitAbove
  case focusSplitBelow

  case toggleDebugOverlay

  case browserZoomIn
  case browserZoomOut
  case browserResetZoom

  case composerSend
  case composerNewline
  case composerDismissSuggestions

  case questionPickerMove
  case questionPickerSelectByNumber
  case questionPickerToggle
  case questionPickerSubmit
  case questionPickerDismiss

  var id: String { rawValue }
}

enum ShortcutCategory: String, CaseIterable, Identifiable, Sendable {
  case chats = "Chats"
  case tabsAndSplits = "Tabs & Splits"
  case view = "View"
  case browser = "Browser"
  case composer = "Composer"
  case questionPicker = "Question Picker"

  var id: String { rawValue }
}

struct ShortcutDefinition: Identifiable, Sendable {
  let id: ShortcutID
  let title: String
  let combo: ShortcutCombo?
  let alternateCombos: [ShortcutCombo]
  let displayOverride: String?
  let category: ShortcutCategory
  let context: String?

  init(
    _ id: ShortcutID,
    _ title: String,
    _ combo: ShortcutCombo?,
    alternates alternateCombos: [ShortcutCombo] = [],
    displayOverride: String? = nil,
    category: ShortcutCategory,
    context: String? = nil
  ) {
    self.id = id
    self.title = title
    self.combo = combo
    self.alternateCombos = alternateCombos
    self.displayOverride = displayOverride
    self.category = category
    self.context = context
  }

  var displayString: String? {
    displayOverride ?? combo.map { ([$0] + alternateCombos).map(\.displayString).joined(separator: " / ") }
  }

  var accessibilityDescription: String? {
    combo.map { ([$0] + alternateCombos).map(\.accessibilityDescription).joined(separator: " or ") }
  }
}

enum ShortcutCatalog {
  static func definition(for id: ShortcutID) -> ShortcutDefinition {
    definition(for: id, refreshed: FeatureFlag.sidebarRefresh.isEnabled)
  }

  private static func definition(for id: ShortcutID, refreshed: Bool) -> ShortcutDefinition {
    switch id {
    case .newChat:
      ShortcutDefinition(.newChat, "New Chat", ShortcutCombo("n", .command), category: .chats)
    case .newProject:
      ShortcutDefinition(.newProject, "New Project…", ShortcutCombo("n", [.command, .shift]), category: .chats)
    case .archiveWorkspace:
      ShortcutDefinition(
        .archiveWorkspace, "Archive Workspace", ShortcutCombo("a", [.command, .shift]), category: .chats,
        context: "Archives the workspace on screen")

    case .newTab:
      ShortcutDefinition(.newTab, "New Tab", ShortcutCombo("t", .command), category: .tabsAndSplits)
    case .closeSplit:
      ShortcutDefinition(
        .closeSplit, "Close Split", ShortcutCombo("w", .command),
        category: .tabsAndSplits,
        context: "Closes the selected tab when a pane has focus"
      )
    case .closeTab:
      ShortcutDefinition(.closeTab, "Close Tab", nil, category: .tabsAndSplits)
    case .reopenClosedPane:
      ShortcutDefinition(
        .reopenClosedPane, "Reopen Closed Pane", ShortcutCombo("t", [.command, .shift]),
        category: .tabsAndSplits,
        context: "Brings back the most recently closed pane of this workspace"
      )
    case .selectTab:
      ShortcutDefinition(
        .selectTab, "Select Tab 1–9", nil,
        displayOverride: "⌘1–⌘9", category: .tabsAndSplits
      )
    case .previousTab:
      refreshed
        ? ShortcutDefinition(
          .previousTab, "Previous Sidebar Item", ShortcutCombo("[", [.command, .shift]), category: .tabsAndSplits,
          context: "Previous tab while the sidebar is hidden")
        : ShortcutDefinition(
          .previousTab, "Previous Tab", ShortcutCombo("[", [.command, .shift]), category: .tabsAndSplits)
    case .nextTab:
      refreshed
        ? ShortcutDefinition(
          .nextTab, "Next Sidebar Item", ShortcutCombo("]", [.command, .shift]), category: .tabsAndSplits,
          context: "Next tab while the sidebar is hidden")
        : ShortcutDefinition(.nextTab, "Next Tab", ShortcutCombo("]", [.command, .shift]), category: .tabsAndSplits)
    case .previousTabInWorkspace:
      ShortcutDefinition(
        .previousTabInWorkspace, "Previous Tab in Workspace",
        refreshed ? ShortcutCombo(.leftArrow, [.command, .option]) : nil, category: .tabsAndSplits)
    case .nextTabInWorkspace:
      ShortcutDefinition(
        .nextTabInWorkspace, "Next Tab in Workspace",
        refreshed ? ShortcutCombo(.rightArrow, [.command, .option]) : nil, category: .tabsAndSplits)
    case .previousWorkspace:
      ShortcutDefinition(
        .previousWorkspace, "Previous Workspace", refreshed ? ShortcutCombo(.upArrow, [.command, .option]) : nil,
        category: .tabsAndSplits)
    case .nextWorkspace:
      ShortcutDefinition(
        .nextWorkspace, "Next Workspace", refreshed ? ShortcutCombo(.downArrow, [.command, .option]) : nil,
        category: .tabsAndSplits)
    case .previousSplit:
      ShortcutDefinition(.previousSplit, "Previous Split", ShortcutCombo("[", .command), category: .tabsAndSplits)
    case .nextSplit:
      ShortcutDefinition(.nextSplit, "Next Split", ShortcutCombo("]", .command), category: .tabsAndSplits)
    case .splitLeft:
      ShortcutDefinition(.splitLeft, "Split Left", nil, category: .tabsAndSplits)
    case .splitRight:
      ShortcutDefinition(.splitRight, "Split Right", ShortcutCombo("d", .command), category: .tabsAndSplits)
    case .splitUp:
      ShortcutDefinition(.splitUp, "Split Up", nil, category: .tabsAndSplits)
    case .splitDown:
      ShortcutDefinition(
        .splitDown, "Split Down", ShortcutCombo("d", [.command, .shift]), category: .tabsAndSplits)
    case .focusSplitLeft:
      ShortcutDefinition(
        .focusSplitLeft, "Focus Split Left", refreshed ? nil : ShortcutCombo(.leftArrow, [.command, .option]),
        category: .tabsAndSplits)
    case .focusSplitRight:
      ShortcutDefinition(
        .focusSplitRight, "Focus Split Right", refreshed ? nil : ShortcutCombo(.rightArrow, [.command, .option]),
        category: .tabsAndSplits)
    case .focusSplitAbove:
      ShortcutDefinition(
        .focusSplitAbove, "Focus Split Above", refreshed ? nil : ShortcutCombo(.upArrow, [.command, .option]),
        category: .tabsAndSplits)
    case .focusSplitBelow:
      ShortcutDefinition(
        .focusSplitBelow, "Focus Split Below", refreshed ? nil : ShortcutCombo(.downArrow, [.command, .option]),
        category: .tabsAndSplits)

    case .toggleDebugOverlay:
      ShortcutDefinition(
        .toggleDebugOverlay, "Toggle Debug Overlay", ShortcutCombo("`", .command), category: .view)

    case .browserZoomIn:
      ShortcutDefinition(
        .browserZoomIn, "Zoom In", ShortcutCombo("=", .command),
        displayOverride: "⌘+ / ⌘=", category: .browser, context: "While browsing")
    case .browserZoomOut:
      ShortcutDefinition(
        .browserZoomOut, "Zoom Out", ShortcutCombo("-", .command), category: .browser,
        context: "While browsing")
    case .browserResetZoom:
      ShortcutDefinition(
        .browserResetZoom, "Reset Zoom", ShortcutCombo("0", .command), category: .browser,
        context: "While browsing")

    case .composerSend:
      ShortcutDefinition(
        .composerSend, "Send Message", ShortcutCombo(.return),
        category: .composer, context: "While the composer has focus"
      )
    case .composerNewline:
      ShortcutDefinition(
        .composerNewline, "Insert Line Break", ShortcutCombo(.return, .shift),
        category: .composer, context: "While the composer has focus"
      )
    case .composerDismissSuggestions:
      ShortcutDefinition(
        .composerDismissSuggestions, "Dismiss Suggestions", ShortcutCombo(.escape),
        category: .composer, context: "While the suggestion list is open"
      )

    case .questionPickerMove:
      ShortcutDefinition(
        .questionPickerMove, "Move Between Options", nil,
        displayOverride: "← ↑ → ↓", category: .questionPicker
      )
    case .questionPickerSelectByNumber:
      ShortcutDefinition(
        .questionPickerSelectByNumber, "Select Option by Number", nil,
        displayOverride: "1–9", category: .questionPicker
      )
    case .questionPickerToggle:
      ShortcutDefinition(
        .questionPickerToggle, "Toggle Highlighted Option", ShortcutCombo(" "),
        displayOverride: "Space", category: .questionPicker
      )
    case .questionPickerSubmit:
      ShortcutDefinition(
        .questionPickerSubmit, "Submit Answer", ShortcutCombo(.return), category: .questionPicker)
    case .questionPickerDismiss:
      ShortcutDefinition(
        .questionPickerDismiss, "Dismiss Without Answering", ShortcutCombo(.escape), category: .questionPicker)
    }
  }

  static func combo(for id: ShortcutID) -> ShortcutCombo? {
    definition(for: id).combo
  }

  static func title(for id: ShortcutID) -> String {
    definition(for: id).title
  }

  static func display(for id: ShortcutID) -> String {
    definition(for: id).displayString ?? ""
  }

  static var all: [ShortcutDefinition] {
    ShortcutID.allCases.map { definition(for: $0) }
  }

  static var listedByCategory: [(category: ShortcutCategory, shortcuts: [ShortcutDefinition])] {
    let listable = all.filter { $0.displayString != nil }
    return ShortcutCategory.allCases.compactMap { category in
      let shortcuts = listable.filter { $0.category == category }
      return shortcuts.isEmpty ? nil : (category, shortcuts)
    }
  }
}
