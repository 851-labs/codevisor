import CodevisorCore
import CodevisorUI
import SwiftUI

/// The New Tab button's autocomplete, as the Mac's `+` shows it: a popover
/// of what a new tab can open, filtered as you type, with an address typed
/// into the field opening straight into a browser. Return opens the
/// highlighted (first) match. It stays a popover on iPhone too.
struct NewTabMenu: View {
  @Binding var isPresented: Bool
  let supportsSimulator: Bool
  let client: (any CodevisorServerClienting)?
  let iconCacheNamespace: String
  let onChoose: (NewTabChoice) -> Void

  @State private var query = ""
  @State private var plugins: [PluginNewTabOption] = []

  private struct Row: Identifiable {
    let id: String
    let title: String
    let choice: NewTabChoice
    var systemImage: String?
    var plugin: PluginNewTabOption?
  }

  private var rows: [Row] {
    var rows: [Row] = []
    if let address = NewTabChoice.address(from: query) {
      rows.append(Row(id: "address", title: "Open \(address)", choice: .browser(url: address), systemImage: "safari"))
    }
    rows += NewTabEntry.builtIns(supportsSimulator: supportsSimulator)
      .filter { NewTabEntry.matches($0.title, query: query) }
      .map { Row(id: $0.id, title: $0.title, choice: $0.choice, systemImage: $0.systemImage) }
    rows += plugins.filter { NewTabEntry.matches($0.title, query: query) }
      .map { Row(id: $0.id, title: $0.title, choice: .plugin($0), plugin: $0) }
    return rows
  }

  var body: some View {
    let rows = rows
    VStack(spacing: 0) {
      searchField(first: rows.first)
      Divider()
      if rows.isEmpty {
        Text("No Matching Options")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 20)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(rows) { row in
              rowButton(row, isHighlighted: !query.isEmpty && row.id == rows.first?.id)
            }
          }
          .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(width: 290)
    .presentationCompactAdaptation(.popover)
    .task { plugins = await PluginNewTabOption.load(from: client) }
  }

  private func searchField(first: Row?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search or Enter Address", text: $query)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit {
          if let first { choose(first.choice) }
        }
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  private func rowButton(_ row: Row, isHighlighted: Bool) -> some View {
    Button {
      choose(row.choice)
    } label: {
      HStack(spacing: 12) {
        icon(row)
          .foregroundStyle(.primary)
          .frame(width: 22)
        Text(row.title)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(NewTabRowStyle(isHighlighted: isHighlighted))
  }

  @ViewBuilder
  private func icon(_ row: Row) -> some View {
    if let plugin = row.plugin, let client {
      PluginIconView(
        pluginId: plugin.pluginId, paneType: plugin.paneType, iconPath: plugin.iconPath, client: client,
        cacheNamespace: iconCacheNamespace)
    } else {
      Image(systemName: row.systemImage ?? "puzzlepiece.extension")
    }
  }

  private func choose(_ choice: NewTabChoice) {
    isPresented = false
    onChoose(choice)
  }
}

/// A row highlighted while pressed, or while it's what Return opens.
private struct NewTabRowStyle: ButtonStyle {
  let isHighlighted: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.primary.opacity(configuration.isPressed ? 0.12 : isHighlighted ? 0.07 : 0))
      }
  }
}
