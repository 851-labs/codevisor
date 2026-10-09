import CodevisorCore
import CodevisorUI
import SwiftUI

/// What a new tab opens as.
enum NewTabChoice: Equatable {
  case chat
  case terminal
  /// A browser, on the given address or the default page.
  case browser(url: String?)
  case files
  case review
  case simulator
  case plugin(PluginNewTabOption)

  /// The address a search-field entry names, if it names one: a full URL,
  /// or a host-like word (`example.com`, `localhost:3000`).
  static func address(from query: String) -> String? {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(" ") else { return nil }
    if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      url.host != nil
    {
      return text
    }
    if text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") { return "http://" + text }
    guard let host = URL(string: "https://" + text)?.host, host.contains("."), !host.hasSuffix(".") else { return nil }
    return "https://" + text
  }
}

/// One built-in thing a new tab can open as.
struct NewTabEntry: Identifiable {
  let title: String
  let systemImage: String
  let choice: NewTabChoice
  var id: String { title }

  /// The same entries as the Mac's New Tab menu.
  static func builtIns(supportsSimulator: Bool) -> [NewTabEntry] {
    [
      NewTabEntry(title: "New Chat", systemImage: "bubble.left.and.bubble.right", choice: .chat),
      NewTabEntry(title: "New Terminal", systemImage: "terminal", choice: .terminal),
      NewTabEntry(title: "New Browser", systemImage: "globe", choice: .browser(url: nil)),
      NewTabEntry(title: "Open File", systemImage: "doc.text.magnifyingglass", choice: .files),
      NewTabEntry(title: "Review Changes", systemImage: "plusminus", choice: .review),
    ] + (supportsSimulator ? [NewTabEntry(title: "Open Simulator", systemImage: "iphone", choice: .simulator)] : [])
  }

  static func matches(_ title: String, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces)
    return query.isEmpty || title.localizedStandardContains(query)
  }
}

/// The New Tab sheet: what the tab should be, searchable, with an address
/// typed into the search field opening straight into a browser. The same
/// entries as the Mac's New Tab menu.
struct NewTabSheet: View {
  @Environment(\.dismiss) private var dismiss
  let supportsSimulator: Bool
  let client: (any CodevisorServerClienting)?
  let iconCacheNamespace: String
  let onChoose: (NewTabChoice) -> Void

  @State private var query = ""
  @State private var plugins: [PluginNewTabOption] = []

  private var builtIns: [NewTabEntry] { NewTabEntry.builtIns(supportsSimulator: supportsSimulator) }

  private func matches(_ title: String) -> Bool { NewTabEntry.matches(title, query: query) }

  var body: some View {
    let address = NewTabChoice.address(from: query)
    let entries = builtIns.filter { matches($0.title) }
    let pluginRows = plugins.filter { matches($0.title) }
    NavigationStack {
      List {
        if let address {
          Section {
            row(title: "Open \(address)", choice: .browser(url: address)) { Image(systemName: "safari") }
          }
        }
        if !entries.isEmpty {
          Section {
            ForEach(entries) { entry in
              row(title: entry.title, choice: entry.choice) { Image(systemName: entry.systemImage) }
            }
          }
        }
        if !pluginRows.isEmpty {
          Section("Plugins") {
            ForEach(pluginRows) { option in
              row(title: option.title, choice: .plugin(option)) { pluginIcon(option) }
            }
          }
        }
      }
      .overlay {
        if address == nil, entries.isEmpty, pluginRows.isEmpty {
          ContentUnavailableView.search(text: query)
        }
      }
      .searchable(
        text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or Enter Address"
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .onSubmit(of: .search) {
        if let address {
          choose(.browser(url: address))
        } else if let first = entries.first?.choice ?? pluginRows.first.map(NewTabChoice.plugin) {
          choose(first)
        }
      }
      .navigationTitle("New Tab")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .task { plugins = await PluginNewTabOption.load(from: client) }
  }

  private func row<Icon: View>(title: String, choice: NewTabChoice, @ViewBuilder icon: () -> Icon) -> some View {
    Button {
      choose(choice)
    } label: {
      Label {
        Text(title).foregroundStyle(.primary)
      } icon: {
        icon().foregroundStyle(.tint)
      }
    }
  }

  @ViewBuilder
  private func pluginIcon(_ option: PluginNewTabOption) -> some View {
    if let client {
      PluginIconView(
        pluginId: option.pluginId, paneType: option.paneType, iconPath: option.iconPath, client: client,
        cacheNamespace: iconCacheNamespace)
    } else {
      Image(systemName: "puzzlepiece.extension")
    }
  }

  private func choose(_ choice: NewTabChoice) {
    dismiss()
    onChoose(choice)
  }
}
