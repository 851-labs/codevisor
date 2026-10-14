import CodevisorUI
import SwiftUI

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
    let keys = shortcut.accessibilityDescription ?? shortcut.displayString ?? ""
    guard let context = shortcut.context else { return keys }
    return "\(keys). \(context)"
  }
}

private struct ShortcutKeycapView: View {
  let display: String

  @Environment(\.theme) private var theme

  var body: some View {
    Text(display)
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
