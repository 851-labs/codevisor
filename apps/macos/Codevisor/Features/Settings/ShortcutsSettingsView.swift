import CodevisorUI
import SwiftUI

/// The Settings ▸ Shortcuts tab: a read-only reference for every keyboard
/// shortcut in the app, grouped by area and rendered straight from
/// `ShortcutCatalog` — the same table the menus and the terminal key handlers
/// read, so this list cannot go stale.
struct ShortcutsSettingsView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            ForEach(ShortcutCatalog.listedByCategory, id: \.category) { group in
                Section {
                    ForEach(group.shortcuts) { shortcut in
                        ShortcutRow(shortcut: shortcut)
                    }
                } header: {
                    Text(group.category.rawValue)
                }
            }
        }
        .settingsPaneFormStyle(theme)
    }
}

/// One command: its name (plus the context it applies in, when narrower than
/// the whole window) against its key glyphs.
private struct ShortcutRow: View {
    let shortcut: ShortcutDefinition

    @Environment(\.theme) private var theme

    var body: some View {
        LabeledContent {
            if let display = shortcut.displayString {
                ShortcutKeycapView(display: display)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.title)
                if let context = shortcut.context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(theme.isSystem ? Color.secondary : theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let keys = shortcut.combo?.accessibilityDescription ?? shortcut.displayString ?? ""
        guard let context = shortcut.context else { return keys }
        return "\(keys). \(context)"
    }
}

/// The key glyphs on a subtle keycap, matching how macOS renders shortcuts in
/// menus without pretending to be an editable control.
private struct ShortcutKeycapView: View {
    let display: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(display)
            // 12 pt = the macOS `.callout` text style.
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}
