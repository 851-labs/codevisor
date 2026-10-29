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
    case plugin(pluginId: String, paneType: String)

    var systemImage: String {
      switch self {
      case .chat: "text.bubble"
      case .browser: "globe"
      case .screenSharing: "display"
      case .simulator: "iphone"
      case .terminal: "terminal"
      case .files: "doc.text.magnifyingglass"
      case .review: "plusminus"
      case .plugin: "puzzlepiece.extension"
      }
    }
  }

  let id: String
  let title: String
  let kind: Kind
  var searchTerms: [String] = []
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
      NewTabOption(id: "chat", title: "Side Chat", kind: .chat, searchTerms: ["New Chat"]),
      NewTabOption(id: "browser", title: "Browser", kind: .browser, searchTerms: ["New Browser"]),
      NewTabOption(id: "terminal", title: "Terminal", kind: .terminal, searchTerms: ["New Terminal"]),
      NewTabOption(id: "files", title: "File", kind: .files, searchTerms: ["Open File"]),
      NewTabOption(id: "review", title: "Changes", kind: .review, searchTerms: ["Review Changes"]),
    ]
      + (supportsScreenSharing ? [screenSharingOption] : [])
      + (supportsSimulator ? [simulatorOption] : [])
      + pluginOptions
  }

  private let screenSharingOption = NewTabOption(
    id: "screen-sharing", title: "Desktop", kind: .screenSharing, searchTerms: ["Open Desktop"])

  private let simulatorOption = NewTabOption(
    id: "simulator", title: "Simulator", kind: .simulator, searchTerms: ["Open Simulator"])

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
    .task(id: pluginRevision) {
      await loadPluginOptions()
    }
  }

  private var popup: some View {
    Autocomplete.Suggestions(query: $query, focus: inputFocus) {
      for option in options {
        action(for: option).searchTerms(option.searchTerms)
      }
    }
    .autocompleteSearchLabel("Search new tab options")
    .autocompleteEmptyMessage("No matching options")
    .composerGlassSurface(cornerRadius: Self.popupCornerRadius)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("New tab")
  }

  private func action(for option: NewTabOption) -> Autocomplete.Action {
    guard case let .plugin(pluginId, _) = option.kind, let client else {
      return Autocomplete.Action(option.title, id: option.id, systemImage: option.kind.systemImage) { open(option) }
    }
    return Autocomplete.Action(option.title, id: option.id, action: { open(option) }) {
      PluginIconView(pluginId: pluginId, client: client, cacheNamespace: iconCacheNamespace, side: 16)
    } label: {
      Text(option.title)
    }
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
    case let .plugin(pluginId, paneType):
      group?.convertNewTabPane(
        id: paneId,
        to: .plugin,
        name: option.title,
        pluginId: pluginId,
        pluginPaneType: paneType
      )
    }
  }

  private var pluginRevision: UInt64 {
    environment.mcpStateRevision(for: iconCacheNamespace)
  }

  private func loadPluginOptions() async {
    guard let client, let offers = await PluginPaneOffer.load(from: client) else { return }
    pluginOptions = offers.map { offer in
      NewTabOption(
        id: "plugin:\(offer.id)",
        title: offer.title,
        kind: .plugin(pluginId: offer.pluginId, paneType: offer.paneType)
      )
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
