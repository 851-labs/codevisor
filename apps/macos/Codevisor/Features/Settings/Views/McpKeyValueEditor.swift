import AppKit
import SwiftUI
import CodevisorUI

/// A compact key/value editor using the shared container structure found in
/// System Settings: header, rows, and an integrated add/remove bar.
struct McpKeyValueEditor: View {
  @Environment(\.theme) private var theme
  @Binding var entries: [McpSecretEntry]
  let nameHeading: String
  let namePrompt: String
  let valuePrompt: String
  let emptyLabel: String
  let addLabel: String
  @State private var selection: UUID?

  var body: some View {
    VStack(spacing: 0) {
      columns {
        Text(nameHeading)
          .padding(.horizontal, 12)
      } trailing: {
        Text("Value")
          .padding(.horizontal, 12)
      }
      .font(.body)
      .frame(height: 28)
      .background(containerBackground)

      Divider()
        .overlay(theme.isSystem ? Color.clear : theme.separator)

      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            if entries.isEmpty {
              Text(emptyLabel)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                .background(rowBackground(at: 0))
            } else {
              ForEach($entries) { $entry in
                let entryID = entry.id
                let index = entries.firstIndex(where: { $0.id == entryID }) ?? 0
                let isSelected = selection == entryID

                columns {
                  McpScrollingTextField(
                    text: $entry.name,
                    placeholder: namePrompt,
                    isEditable: !entry.existing,
                    isSelected: isSelected,
                    theme: theme,
                    onFocus: { selection = entryID }
                  )
                  .padding(.horizontal, 12)
                  .accessibilityLabel(nameHeading)
                } trailing: {
                  McpScrollingTextField(
                    text: $entry.value,
                    placeholder: entry.existing ? "Keep saved value" : valuePrompt,
                    isEditable: true,
                    isSelected: isSelected,
                    theme: theme,
                    onFocus: { selection = entryID }
                  )
                  .padding(.horizontal, 12)
                  .accessibilityLabel(
                    "Value for \(entry.name.isEmpty ? nameHeading : entry.name)"
                  )
                }
                .frame(height: 24)
                .background(
                  isSelected
                    ? selectedRowBackground
                    : rowBackground(at: index)
                )
                .contentShape(Rectangle())
                .onTapGesture { selection = entryID }
                .id(entryID)
              }
            }
          }
        }
        .scrollIndicators(entries.count > 4 ? .automatic : .hidden)
        .onChange(of: selection) { _, selectedID in
          guard entries.count > 4, let selectedID else { return }
          proxy.scrollTo(selectedID, anchor: .bottom)
        }
      }
      .frame(height: bodyHeight)

      Divider()
        .overlay(theme.isSystem ? Color.clear : theme.separator)

      HStack(spacing: 0) {
        Button {
          let entry = McpSecretEntry(name: "", value: "", existing: false)
          entries.append(entry)
          selection = entry.id
        } label: {
          Image(systemName: "plus")
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .settingsActionTint(theme)
        .accessibilityLabel(addLabel)
        .help(addLabel)

        Divider()
          .overlay(theme.isSystem ? Color.clear : theme.separator)
          .frame(height: 16)

        Button {
          guard let selection else { return }
          entries.removeAll { $0.id == selection }
          self.selection = nil
        } label: {
          Image(systemName: "minus")
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .settingsActionTint(theme)
        .disabled(selection == nil)
        .accessibilityLabel("Remove selected \(nameHeading.lowercased())")
        .help("Remove Selected")

        Spacer()
      }
      .frame(height: 26)
      .background(containerBackground)
    }
    .background(rowBackground(at: 0))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      if !theme.isSystem {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(theme.border, lineWidth: 1)
      }
    }
    .onChange(of: entries.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
    .accessibilityElement(children: .contain)
  }

  private var bodyHeight: CGFloat {
    let visibleRows = min(max(entries.count, 1), 4)
    return CGFloat(visibleRows * 24)
  }

  private var containerBackground: Color {
    if !theme.isSystem { return theme.cardQuietBackground }
    return Color(nsColor: NSColor.alternatingContentBackgroundColors[1])
  }

  private func rowBackground(at index: Int) -> Color {
    if !theme.isSystem {
      return index.isMultiple(of: 2) ? theme.composerBackground : theme.cardQuietBackground
    }
    let colors = NSColor.alternatingContentBackgroundColors
    return Color(nsColor: colors[index % colors.count])
  }

  private var selectedRowBackground: Color {
    theme.isSystem ? Color(nsColor: .selectedContentBackgroundColor) : theme.rowSelectedBackground
  }

  private func columns<Leading: View, Trailing: View>(
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 0) {
      leading()
        .frame(maxWidth: .infinity, alignment: .leading)
      Divider()
        .overlay(theme.isSystem ? Color.clear : theme.separator)
      trailing()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
