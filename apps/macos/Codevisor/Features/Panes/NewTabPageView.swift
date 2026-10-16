import Autocomplete
import CodevisorCore
import CodevisorUI
import SwiftUI

private struct NewTabOption: Identifiable, Equatable {
  enum Kind: Equatable {
    case chat
    case terminal
    case files
    case review
    case browser
    case screenSharing
    case simulator
    case plugin(pluginId: String, paneType: String, iconPath: String?)
  }

  let id: String
  let title: String
  let kind: Kind
}

struct NewTabPageView: View {
  @Environment(AppEnvironment.self) private var environment
  let paneId: UUID
  let group: PaneGroupModel?
  var onNewChat: (() -> Void)? = nil
  var client: (any CodevisorServerClienting)? = nil
  var iconCacheNamespace = "preview"
  var machineId: String? = nil

  @State private var pluginOptions: [NewTabOption] = []
  @State private var query = ""
  @State private var inputFocus = Autocomplete.InputFocus()

  private static let popupCornerRadius: CGFloat = 18

  private var supportsScreenSharing: Bool {
    guard let machineId else { return false }
    return environment.machines.statusByMachineId[machineId]?.supportsScreenSharing == true
  }

  private var supportsSimulator: Bool {
    guard let machineId else { return false }
    return environment.machines.statusByMachineId[machineId]?.supportsSimulator == true
  }

  private var options: [NewTabOption] {
    [
      NewTabOption(id: "chat", title: "New Chat", kind: .chat),
      NewTabOption(id: "browser", title: "New Browser", kind: .browser),
      NewTabOption(id: "terminal", title: "New Terminal", kind: .terminal),
      NewTabOption(id: "files", title: "Open File", kind: .files),
      NewTabOption(id: "review", title: "Review Changes", kind: .review),
    ]
      + (supportsScreenSharing
        ? [NewTabOption(id: "screen-sharing", title: "Open Desktop", kind: .screenSharing)] : [])
      + (supportsSimulator ? [NewTabOption(id: "simulator", title: "Open Simulator", kind: .simulator)] : [])
      + pluginOptions
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        popup
          .padding(20)
          .frame(maxWidth: .infinity)
          .frame(minHeight: geometry.size.height)
      }
    }
    .simultaneousGesture(
      TapGesture().onEnded {
        group?.onActivated?()
        group?.requestSelectedPaneFocus()
      }
    )
    .onAppear {
      guard let group else { return }
      group.registerNewTabFocus(paneId: paneId) { [weak group, inputFocus, paneId] in
        inputFocus.focus {
          group?.canFocusSelectedPane == true && group?.state.selectedPaneId == paneId
        }
      }
    }
    .onDisappear {
      group?.unregisterNewTabFocus(paneId: paneId)
    }
    .task(id: pluginStateRevision) {
      await loadPluginOptions()
    }
  }

  private var popup: some View {
    Autocomplete.Suggestions(query: $query, focus: inputFocus) {
      for option in options {
        switch option.kind {
        case .chat:
          Autocomplete.Action(option.title, id: option.id, systemImage: "text.bubble") { open(option) }
        case .browser:
          Autocomplete.Action(option.title, id: option.id, systemImage: "globe") { open(option) }
        case .screenSharing:
          Autocomplete.Action(option.title, id: option.id, systemImage: "display") { open(option) }
        case .simulator:
          Autocomplete.Action(option.title, id: option.id, systemImage: "iphone") { open(option) }
        case .terminal:
          Autocomplete.Action(option.title, id: option.id, systemImage: "terminal") { open(option) }
        case .files:
          Autocomplete.Action(option.title, id: option.id, systemImage: "doc.text.magnifyingglass") { open(option) }
        case .review:
          Autocomplete.Action(option.title, id: option.id, systemImage: "plusminus") { open(option) }
        case let .plugin(pluginId, paneType, iconPath):
          Autocomplete.Action(option.title, id: option.id, action: { open(option) }) {
            if let client {
              PluginIconView(
                pluginId: pluginId, paneType: paneType, iconPath: iconPath,
                client: client, cacheNamespace: iconCacheNamespace)
            } else {
              Image(systemName: "puzzlepiece.extension")
            }
          } label: {
            Text(option.title)
          }
        }
      }
    }
    .autocompleteSearchLabel("Search new tab options")
    .autocompleteEmptyMessage("No matching options")
    .composerGlassSurface(cornerRadius: Self.popupCornerRadius)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("New tab")
  }

  private func open(_ option: NewTabOption) {
    switch option.kind {
    case .files:
      group?.openFiles(id: paneId)
    case .chat:
      if let onNewChat {
        onNewChat()
      } else {
        group?.convertNewTabPane(id: paneId, to: .chat)
      }
    case .screenSharing:
      group?.convertNewTabPane(id: paneId, to: .screenSharing)
    case .simulator:
      group?.convertNewTabPane(id: paneId, to: .simulator)
    case .browser:
      group?.convertNewTabPane(id: paneId, to: .browser)
    case .review:
      group?.convertNewTabPane(id: paneId, to: .review)
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
