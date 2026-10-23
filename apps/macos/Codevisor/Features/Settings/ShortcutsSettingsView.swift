import CodevisorUI
import SwiftUI

struct ShortcutsSettingsView: View {
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
    .formStyle(.grouped)
  }
}

private struct ShortcutRow: View {
  let shortcut: ShortcutDefinition

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
            .font(.callout)
            .foregroundStyle(.secondary)
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

  var body: some View {
    Text(display)
      .font(.callout)
      .monospacedDigit()
      .foregroundStyle(.primary)
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
