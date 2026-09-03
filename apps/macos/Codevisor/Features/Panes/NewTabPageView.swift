//  The Chrome-style "New tab" page: what a group shows when its last real
//  pane closes. The empty state IS a tab (the strip never lies about what's
//  open); this page offers what to open in its place — choosing converts
//  the placeholder pane in place, so the tab slot and selection carry over.
//  Everything opens in the workspace's one working directory.
//
//  The offer is an Autocomplete popup rendered inline: type to filter, ↑↓
//  to move, Return to open — the same picker the composer uses for models.

import Autocomplete
import CodevisorCore
import CodevisorUI
import SwiftUI

/// One thing the New Tab page can open.
private struct NewTabOption: Identifiable, Equatable {
  enum Kind: Equatable {
    case chat
    case terminal
    case plugin(pluginId: String, paneType: String, iconPath: String?)
  }

  let id: String
  let title: String
  let kind: Kind
}

struct NewTabPageView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  /// The placeholder pane this page belongs to.
  let paneId: UUID
  /// The owning group; conversion happens through it.
  let group: PaneGroupModel?
  /// Creates the chat SESSION eagerly and converts the placeholder into
  /// an established chat pane (wired by the container, which owns session
  /// creation). Nil (previews) falls back to a draft conversion.
  var onNewChat: (() -> Void)? = nil
  /// The machine's API client, for the machine-scoped plugin pane rows.
  /// Nil (previews, machineless groups) shows no plugin rows.
  var client: (any CodevisorServerClienting)? = nil
  var iconCacheNamespace = "preview"

  @State private var pluginOptions: [NewTabOption] = []
  @State private var query = ""
  @State private var highlight = Autocomplete.Highlight<String>(navigation: .inline)
  /// Focusing this pane focuses the picker's input — never on appearance,
  /// only when the group says the pane is the one the user is working in.
  @State private var inputFocus = Autocomplete.InputFocus()

  private static let metrics = Autocomplete.Style.xcodeMenu.metrics
  private static let popupCornerRadius: CGFloat = 18

  private var options: [NewTabOption] {
    [
      NewTabOption(id: "chat", title: "New Chat", kind: .chat),
      NewTabOption(id: "terminal", title: "New Terminal", kind: .terminal),
    ] + pluginOptions
  }

  private var matches: [NewTabOption] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return options }
    return options.filter { Autocomplete.Filter.contains.matches($0.title, query: query) }
  }

  var body: some View {
    // Scrolls when the pane is too short for the popup — fixed-height
    // content would otherwise fight the group's layout and squeeze the tab
    // bar. Centered while it fits.
    GeometryReader { geometry in
      ScrollView {
        popup
          .padding(20)
          .frame(maxWidth: .infinity)
          .frame(minHeight: geometry.size.height)
      }
    }
    .background(theme.paneBackground)
    // The page has no editor of its own, so whitespace clicks explicitly
    // activate the group, which routes focus to the picker's input.
    .simultaneousGesture(
      TapGesture().onEnded {
        group?.focusSelectedPane()
      }
    )
    .onAppear {
      group?.registerNewTabFocus(paneId: paneId) { inputFocus.focus() }
    }
    .onDisappear {
      group?.unregisterNewTabFocus(paneId: paneId)
    }
    .task(id: pluginStateRevision) {
      await loadPluginOptions()
    }
  }

  private var popup: some View {
    Autocomplete.Root(highlight: highlight, onDismiss: { query = "" }) {
      Autocomplete.Input(
        text: $query, prompt: "Search", accessibilityLabel: "Search new tab options", focus: inputFocus
      )
      // Pinned to the unfiltered count so filtering never resizes the popup.
      Autocomplete.List(height: Self.metrics.listHeight(itemCount: options.count)) {
        if matches.isEmpty {
          Autocomplete.Empty("No matching options")
        }
        ForEach(matches) { option in
          switch option.kind {
          case .chat:
            Autocomplete.Item(id: option.id, icon: Image(systemName: "text.bubble"), action: { open(option) }) { _ in
              Text(option.title)
            }
          case .terminal:
            Autocomplete.Item(id: option.id, icon: Image(systemName: "terminal"), action: { open(option) }) { _ in
              Text(option.title)
            }
          case let .plugin(pluginId, paneType, iconPath):
            Autocomplete.Item(id: option.id, action: { open(option) }) {
              if let client {
                PluginIconView(
                  pluginId: pluginId,
                  paneType: paneType,
                  iconPath: iconPath,
                  client: client,
                  cacheNamespace: iconCacheNamespace
                )
              } else {
                Image(systemName: "puzzlepiece.extension")
              }
            } label: { _ in
              Text(option.title)
            }
          }
        }
      }
    }
    .frame(width: max(Self.metrics.popupWidth(fitting: options.map(\.title)), 280))
    .composerGlassSurface(cornerRadius: Self.popupCornerRadius)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("New tab")
  }

  private func open(_ option: NewTabOption) {
    switch option.kind {
    case .chat:
      if let onNewChat {
        onNewChat()
      } else {
        group?.convertNewTabPane(id: paneId, to: .chat)
      }
    case .terminal:
      group?.convertNewTabPane(id: paneId, to: .terminal)
    case let .plugin(pluginId, paneType, _):
      group?.convertNewTabPane(
        id: paneId,
        to: .plugin,
        name: option.title,
        pluginId: pluginId,
        pluginPaneType: paneType
      )
    }
  }

  private var pluginStateRevision: UInt64 {
    environment.pluginStateRevision(for: iconCacheNamespace)
  }

  /// Machine-scoped plugin pane rows. Errors (older servers without the
  /// plugins feature, unreachable machines) just leave the rows out — the
  /// page's built-in options never depend on the request.
  private func loadPluginOptions() async {
    guard let client else { return }
    guard let plugins = try? await client.listPlugins() else { return }
    pluginOptions = plugins.flatMap { plugin in
      plugin.panes.map { pane in
        NewTabOption(
          id: "plugin:\(plugin.id)|\(pane.type)",
          title: pane.title,
          kind: .plugin(pluginId: plugin.id, paneType: pane.type, iconPath: pane.iconPath ?? plugin.iconPath)
        )
      }
    }
  }
}

#if DEBUG
  #Preview {
    NewTabPageView(
      paneId: UUID(),
      group: nil
    )
    .frame(width: 700, height: 480)
  }
#endif
