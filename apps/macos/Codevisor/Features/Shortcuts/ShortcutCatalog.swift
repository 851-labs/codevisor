import SwiftUI

/// Every command in the app that has (or could have) a keyboard shortcut.
///
/// The case order here is the order rows appear in Settings ▸ Shortcuts.
enum ShortcutID: String, CaseIterable, Identifiable, Sendable {
    // Chats
    case newChat
    case newProject

    // Tabs & splits
    case newTab
    case closeSplit
    case closeTab
    case selectTab
    case previousTab
    case nextTab
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

    // View
    case toggleBottomPanel
    case toggleDebugOverlay

    // Composer
    case composerSend
    case composerNewline
    case composerDismissSuggestions

    // Question picker
    case questionPickerMove
    case questionPickerSelectByNumber
    case questionPickerToggle
    case questionPickerSubmit
    case questionPickerDismiss

    var id: String { rawValue }
}

/// The Settings ▸ Shortcuts section a command is listed under.
enum ShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case chats = "Chats"
    case tabsAndSplits = "Tabs & Splits"
    case view = "View"
    case composer = "Composer"
    case questionPicker = "Question Picker"

    var id: String { rawValue }
}

/// One command's title, shortcut, and where it applies.
struct ShortcutDefinition: Identifiable, Sendable {
    let id: ShortcutID
    /// The menu-item title, and the label in the Shortcuts list.
    let title: String
    /// `nil` for menu items that intentionally have no key equivalent
    /// (Close Tab, Split Left/Up) and for the ranged shortcuts below.
    let combo: ShortcutCombo?
    /// Set for shortcuts that are a range rather than one combo, e.g. ⌘1–⌘9.
    /// Takes precedence over `combo` when rendering.
    let displayOverride: String?
    let category: ShortcutCategory
    /// Where the shortcut applies, when that isn't "anywhere in the window".
    let context: String?

    init(
        _ id: ShortcutID,
        _ title: String,
        _ combo: ShortcutCombo?,
        displayOverride: String? = nil,
        category: ShortcutCategory,
        context: String? = nil
    ) {
        self.id = id
        self.title = title
        self.combo = combo
        self.displayOverride = displayOverride
        self.category = category
        self.context = context
    }

    /// What the Shortcuts list renders on the right-hand side, or `nil` for
    /// commands that have no key equivalent at all.
    var displayString: String? {
        displayOverride ?? combo?.displayString
    }
}

/// The app's single source of truth for keyboard shortcuts.
///
/// Menus read their titles and key equivalents from here (via `ShortcutButton`),
/// the AppKit key-equivalent paths match events against the same combos (via
/// `ShortcutCatalog.paneCommand(for:)`), and Settings ▸ Shortcuts renders the
/// whole table. Change a shortcut in one place and all three follow.
///
/// Shortcuts are not user-remappable yet. When they become so, the override map
/// belongs behind `combo(for:)` — every consumer already goes through it.
enum ShortcutCatalog {
    /// Exhaustive by construction: adding a `ShortcutID` fails to compile until
    /// it is defined here.
    static func definition(for id: ShortcutID) -> ShortcutDefinition {
        switch id {
        case .newChat:
            ShortcutDefinition(.newChat, "New Chat", ShortcutCombo("n", .command), category: .chats)
        case .newProject:
            ShortcutDefinition(.newProject, "New Project…", ShortcutCombo("n", [.command, .shift]), category: .chats)

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
        case .selectTab:
            ShortcutDefinition(
                .selectTab, "Select Tab 1–9", nil,
                displayOverride: "⌘1–⌘9", category: .tabsAndSplits
            )
        case .previousTab:
            ShortcutDefinition(
                .previousTab, "Previous Tab", ShortcutCombo("[", [.command, .shift]), category: .tabsAndSplits)
        case .nextTab:
            ShortcutDefinition(.nextTab, "Next Tab", ShortcutCombo("]", [.command, .shift]), category: .tabsAndSplits)
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
                .focusSplitLeft, "Focus Split Left", ShortcutCombo(.leftArrow, [.command, .option]),
                category: .tabsAndSplits)
        case .focusSplitRight:
            ShortcutDefinition(
                .focusSplitRight, "Focus Split Right", ShortcutCombo(.rightArrow, [.command, .option]),
                category: .tabsAndSplits)
        case .focusSplitAbove:
            ShortcutDefinition(
                .focusSplitAbove, "Focus Split Above", ShortcutCombo(.upArrow, [.command, .option]),
                category: .tabsAndSplits)
        case .focusSplitBelow:
            ShortcutDefinition(
                .focusSplitBelow, "Focus Split Below", ShortcutCombo(.downArrow, [.command, .option]),
                category: .tabsAndSplits)

        case .toggleBottomPanel:
            ShortcutDefinition(.toggleBottomPanel, "Toggle Bottom Panel", ShortcutCombo("j", .command), category: .view)
        case .toggleDebugOverlay:
            ShortcutDefinition(
                .toggleDebugOverlay, "Toggle Debug Overlay", ShortcutCombo("`", .command), category: .view)

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

    /// The active combo for a command. The one place a future user-override map
    /// needs to hook into.
    static func combo(for id: ShortcutID) -> ShortcutCombo? {
        definition(for: id).combo
    }

    static func title(for id: ShortcutID) -> String {
        definition(for: id).title
    }

    /// The glyph string for a command, e.g. "⌘T". Empty for commands with no
    /// key equivalent, so it is safe to interpolate into tooltips.
    static func display(for id: ShortcutID) -> String {
        definition(for: id).displayString ?? ""
    }

    static var all: [ShortcutDefinition] {
        ShortcutID.allCases.map(definition(for:))
    }

    /// Every category that has at least one listable shortcut, in declaration
    /// order, each with its rows. Commands with no key equivalent are dropped —
    /// they exist in the catalog only so menus can source their titles here.
    static var listedByCategory: [(category: ShortcutCategory, shortcuts: [ShortcutDefinition])] {
        let listable = all.filter { $0.displayString != nil }
        return ShortcutCategory.allCases.compactMap { category in
            let shortcuts = listable.filter { $0.category == category }
            return shortcuts.isEmpty ? nil : (category, shortcuts)
        }
    }

    /// The ⌘1–⌘9 hint shown on the nth workspace tab.
    static func tabSelectionHint(index: Int) -> String {
        "⌘\(index + 1)"
    }
}
