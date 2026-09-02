import SwiftUI
import CodevisorUI

/// A theme-token-backed macOS pop-up button for the short authorization list.
/// Menu items retain the familiar checkmark selection while the collapsed
/// control uses the same surface and border language as the themed form.
struct McpThemedAuthorizationPicker: View {
  private struct Option: Identifiable {
    let id: String
    let label: String
  }

  @Binding var selection: String
  let automaticLabel: String
  let theme: Theme

  private var options: [Option] {
    [
      Option(id: "auto", label: automaticLabel),
      Option(id: "none", label: "None"),
      Option(id: "bearer", label: "Bearer Token"),
      Option(id: "oauth", label: "OAuth"),
    ]
  }

  private var selectedLabel: String {
    options.first { $0.id == selection }?.label ?? automaticLabel
  }

  var body: some View {
    Menu {
      ForEach(options) { option in
        Button {
          selection = option.id
        } label: {
          if selection == option.id {
            Label(option.label, systemImage: "checkmark")
          } else {
            Text(option.label)
          }
        }
      }
    } label: {
      HStack(spacing: 8) {
        Text(selectedLabel)
          .foregroundStyle(theme.textPrimary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.medium))
          .foregroundStyle(theme.textSecondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity)
      .frame(height: 28)
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(theme.composerBackground)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(theme.border, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Authorization")
    .accessibilityValue(selectedLabel)
  }
}
