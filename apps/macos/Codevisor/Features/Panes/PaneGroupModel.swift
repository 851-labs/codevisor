import Autocomplete
import Foundation
import Observation
import SwiftUI
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import StreamMarkdown

@MainActor
@Observable
final class PaneGroupModel: Identifiable {
  private(set) var sessionId: UUID?
  var state: PaneGroupState
  @ObservationIgnored var chatContent: ((PaneDescriptorState) -> AnyView)?

  @ObservationIgnored var live: [UUID: any Pane] = [:] {
    didSet { browserIndex?.update(owner: ObjectIdentifier(self), previous: oldValue, current: live) }
  }
  @ObservationIgnored weak var browserIndex: BrowserPaneIndex?
  @ObservationIgnored var wiring: PaneGroupWiring?
  @ObservationIgnored private let repository: any PaneGroupRepository
  @ObservationIgnored private var makeContext: (PaneDescriptorState) -> PaneContext
  @ObservationIgnored private(set) var pluginIconClient: (any CodevisorServerClienting)?
  @ObservationIgnored private(set) var pluginIconCacheNamespace: String
  @ObservationIgnored var requestComposerFocus: (() -> Void)?
  @ObservationIgnored var requestBackgroundFocus: (() -> Void)?
  @ObservationIgnored private var newTabFocusHandlers: [UUID: () -> Void] = [:]
  @ObservationIgnored private var pendingNewTabFocus: UUID?

  func registerNewTabFocus(paneId: UUID, handler: @escaping () -> Void) {
    newTabFocusHandlers[paneId] = handler
    if pendingNewTabFocus == paneId {
      pendingNewTabFocus = nil
      if canFocusSelectedPane, state.selectedPaneId == paneId { handler() }
    }
  }

  func unregisterNewTabFocus(paneId: UUID) {
    newTabFocusHandlers[paneId] = nil
  }
  @ObservationIgnored var onPaneWillClose: ((PaneDescriptorState) -> Void)?
  @ObservationIgnored var onPaneClosed: ((PaneDescriptorState) -> Void)?
  @ObservationIgnored var onPaneChanged: ((PaneDescriptorState) -> Void)?
  @ObservationIgnored var onPaneEdited: ((UUID) -> Void)?
  @ObservationIgnored var onPaneRemoved: ((PaneDescriptorState) -> Void)?
  @ObservationIgnored var isWorkspaceFinalPane: ((PaneDescriptorState) -> Bool)?
  @ObservationIgnored var isWorkspaceMainChat: ((PaneDescriptorState) -> Bool)?
  @ObservationIgnored var canDissolve: (() -> Bool)?
  @ObservationIgnored var onActivated: (() -> Void)?
  @ObservationIgnored var isFocusCurrent: (() -> Bool)?
  @ObservationIgnored let deferredFocus = DeferredPaneFocus()
  @ObservationIgnored var presentedPaneIDs: Set<UUID> = []
  @ObservationIgnored var workspaceCommandHandler: ((PaneGroupCommand) -> Bool)?

  init(
    sessionId: UUID?,
    repository: any PaneGroupRepository,
    pluginIconClient: (any CodevisorServerClienting)? = nil,
    pluginIconCacheNamespace: String = "preview",
    makeContext: @escaping (PaneDescriptorState) -> PaneContext
  ) {
    self.sessionId = sessionId
    self.repository = repository
    self.pluginIconClient = pluginIconClient
    self.pluginIconCacheNamespace = pluginIconCacheNamespace
    self.makeContext = makeContext
    if let stored = repository.load(sessionId: sessionId) {
      self.state = stored
    } else {
      let initial =
        sessionId.map { PaneGroupState.centerInitial(sessionId: $0) }
        ?? .centerInitialWithoutChat()
      self.state = initial
      repository.save(initial, sessionId: sessionId)
    }
    ChromiumAutomationBridge.shared.addGroup(self)
  }

  func adoptSession(
    _ sessionId: UUID,
    makeContext: @escaping (PaneDescriptorState) -> PaneContext
  ) {
    guard self.sessionId == nil else { return }
    self.sessionId = sessionId
    self.makeContext = makeContext
    for pane in state.panes where pane.kind == .document || pane.kind == .review {
      discardLivePane(id: pane.id)
    }
  }

  func canHostBrowserAutomation(sessionId requested: String, machineId: String) -> Bool {
    guard createBrowserTab != nil, let descriptor = state.panes.first,
      makeContext(descriptor).machine.id == machineId
    else { return false }
    return sessionId?.uuidString.lowercased() == requested.lowercased()
      || state.panes.contains { $0.chatSessionId?.uuidString.lowercased() == requested.lowercased() }
  }

  @ObservationIgnored var createBrowserTab: ((String) -> ChromiumBrowserModel?)?
  @ObservationIgnored var openBrowserLink: ((UUID, String, BrowserLinkDestination, CVChromiumView?) -> Bool)?

  func openFiles(id: UUID) {
    guard let index = state.panes.firstIndex(where: { $0.id == id }) else { return }
    let context = makeContext(state.panes[index])
    let root = context.workspaceRootDirectory ?? context.session?.cwd ?? context.project.folderURL.path
    let path = root + "/"
    let pane = PaneDescriptorState(
      id: id, kind: .document, name: FileDocumentLocation.name(path), terminalKey: id.uuidString, documentPath: path)
    discardLivePane(id: id)
    state.panes[index] = pane
    persist()
    onPaneChanged?(pane)
  }

  func pane(for descriptor: PaneDescriptorState) -> any Pane {
    if let existing = live[descriptor.id] { return existing }
    let pane: any Pane
    switch descriptor.kind {
    case .browser:
      let browser = BrowserPane(context: makeContext(descriptor), descriptor: descriptor)
      wireBrowser(browser)
      pane = browser
    case .screenSharing:
      let sharing = ScreenSharingPane(context: makeContext(descriptor), descriptor: descriptor)
      wireScreenSharing(sharing)
      pane = sharing
    case .document:
      pane = makeDocumentPane(for: descriptor)
    case .simulator:
      pane = makeSimulatorPane(for: descriptor)
    case .review:
      pane = makeReviewPane(for: descriptor)
    case .terminal:
      let terminal = TerminalPane(context: makeContext(descriptor))
      terminal.onContentAttached = { [weak self] in self?.requestSelectedPaneFocus() }
      pane = terminal
    case .plugin:
      pane = PluginPaneFactory.make(context: makeContext(descriptor), descriptor: descriptor) { [weak self] title in
        self?.renamePane(id: descriptor.id, to: title)
      }
    case .chat, .newTab, .subagent, .transcript:
      let chat = ChatPane(id: descriptor.id)
      wireChatHost(chat, paneId: descriptor.id)
      pane = chat
    }
    pane.onGroupCommand = { [weak self] command in self?.handleCommand(command) }
    pane.onFocusChanged = { [weak self] focused in
      self?.paneFocusChanged(focused: focused)
    }
    live[descriptor.id] = pane
    return pane
  }

  private func makeDocumentPane(for descriptor: PaneDescriptorState) -> FilePane {
    let document = FilePane(context: makeContext(descriptor), descriptor: descriptor)
    document.model.onEdit = { [weak self] in self?.onPaneEdited?(descriptor.id) }
    document.model.onClose = { [weak self] in self?.closeTab(id: descriptor.id) }
    document.model.onOpenWebLink = { [links = webLinkActions(sourcePaneId: descriptor.id)] in links.open($0, .newTab) }
    document.onNavigate = { [weak self] path in
      guard let self, let index = state.panes.firstIndex(where: { $0.id == descriptor.id }) else { return }
      state.panes[index].documentPath = path
      state.panes[index].name = FileDocumentLocation.name(path)
      persist()
      onPaneChanged?(state.panes[index])
    }
    return document
  }

  private func makeSimulatorPane(for descriptor: PaneDescriptorState) -> AppleSimulatorPane {
    let simulator = AppleSimulatorPane(context: makeContext(descriptor), descriptor: descriptor)
    simulator.onPreferencesChanged = { [weak self, weak simulator] preferences in
      guard let self, let simulator,
        let index = self.state.panes.firstIndex(where: { $0.id == simulator.id }),
        self.state.panes[index].simulator != preferences
      else { return }
      self.state.panes[index].simulator = preferences
      self.persist()
      self.onPaneChanged?(self.state.panes[index])
    }
    simulator.canFocusChooser = { [weak self] in
      self?.canFocusSelectedPane == true && self?.state.selectedPaneId == descriptor.id
    }
    return simulator
  }

  private func makeReviewPane(for descriptor: PaneDescriptorState) -> ReviewPane {
    let review = ReviewPane(context: makeContext(descriptor), descriptor: descriptor)
    review.model.onPreferencesChange = { [weak self] preferences in
      guard let self, let index = state.panes.firstIndex(where: { $0.id == descriptor.id }) else { return }
      state.panes[index].review = preferences
      persist()
      onPaneChanged?(state.panes[index])
    }
    return review
  }

  func wireScreenSharing(_ sharing: ScreenSharingPane) {
    sharing.onFocus = { [weak self, weak sharing] in
      guard let self, let sharing, self.canFocusSelectedPane, self.state.selectedPaneId == sharing.id else { return }
      self.requestBackgroundFocus?()
    }
    sharing.onPreferencesChanged = { [weak self, weak sharing] preferences in
      guard let self, let sharing,
        let index = self.state.panes.firstIndex(where: { $0.id == sharing.id }),
        self.state.panes[index].screenSharing != preferences
      else { return }
      self.state.panes[index].screenSharing = preferences
      self.persist()
      self.onPaneChanged?(self.state.panes[index])
    }
  }

  func wireBrowser(_ browser: BrowserPane) {
    let id = browser.id
    browser.wiring = { [weak self] model in
      model.onOpenLink = { [weak self] url, destination, popup in
        self?.openBrowserLink?(id, url, destination, popup) ?? false
      }
      model.onClose = { [weak self] in self?.closePane(id: id) }
      model.onSelect = { [weak self] in self?.select(id: id) }
      model.onNavigate = { [weak self] url, title in
        self?.updateBrowserPane(id) { BrowserPaneUpdate.navigated($0, to: url, title: title) }
      }
      model.favicons.onShare = { [weak self] reference, page in
        self?.updateBrowserPane(id) { BrowserPaneUpdate.favicon(reference, savedFor: page, on: $0) }
      }
    }
  }

  private func updateBrowserPane(_ id: UUID, _ update: (PaneDescriptorState) -> PaneDescriptorState?) {
    guard let index = state.panes.firstIndex(where: { $0.id == id }), let updated = update(state.panes[index])
    else { return }

    state.panes[index] = updated
    persist()
    onPaneChanged?(updated)
  }

  func wireChatHost(_ chat: ChatPane, paneId: UUID) {
    chat.onFocus = { [weak self, paneId] in
      guard let self,
        let descriptor = self.state.panes.first(where: { $0.id == paneId })
      else { return }
      self.pendingNewTabFocus = nil
      switch descriptor.kind {
      case .chat:
        self.requestComposerFocus?()
      case .newTab:
        if let focusPage = self.newTabFocusHandlers[paneId] {
          focusPage()
        } else {
          self.pendingNewTabFocus = paneId
          self.requestBackgroundFocus?()
        }
      case .subagent, .transcript:
        self.requestBackgroundFocus?()
      case .terminal, .plugin, .document, .browser, .screenSharing, .review, .simulator:
        break
      }
    }
    chat.contentProvider = { [weak self, paneId] in
      guard let self,
        let current = self.state.panes.first(where: { $0.id == paneId }),
        let content = self.chatContent
      else { return AnyView(EmptyView()) }
      return AnyView(
        content(current).environment(\.transcriptWebLinkActions, self.webLinkActions(sourcePaneId: paneId)))
    }
  }

  private func webLinkActions(sourcePaneId: UUID) -> MarkdownWebLinkActions {
    MarkdownWebLinkActions { [weak self] url, destination in
      let destination: BrowserLinkDestination =
        switch destination {
        case .newTab: .foregroundTab
        case .newWindow: .window
        case .split: .split(.trailing)
        }
      return self?.openBrowserLink?(sourcePaneId, url.absoluteString, destination, nil) ?? false
    }
  }

  func paneFocusChanged(focused: Bool) {
    if focused { onActivated?() }
  }

  func handleCommand(_ command: PaneGroupCommand) {
    if workspaceCommandHandler?(command) == true { return }
    switch command {
    case .newTab:
      addNewTabPane()
      requestSelectedPaneFocus()
    case .nextTab, .previousTab, .nextTabInWorkspace, .previousTabInWorkspace:
      let panes = state.panes
      guard panes.count > 1,
        let index = panes.firstIndex(where: { $0.id == state.selectedPaneId })
      else { return }
      let step: Int =
        switch command {
        case .nextTab, .nextTabInWorkspace: 1
        default: -1
        }
      let target = panes[(index + step + panes.count) % panes.count]
      select(id: target.id)
      requestSelectedPaneFocus()
    case .selectTab(let index):
      guard state.panes.indices.contains(index) else { return }
      select(id: state.panes[index].id)
      requestSelectedPaneFocus()
    case .split, .focusSplit, .previousSplit, .nextSplit, .reopenClosedPane, .previousWorkspace, .nextWorkspace:
      return
    case .closeTab:
      guard let selected = state.selectedPane else { return }
      closeTab(id: selected.id)
    }
  }

  func closeTab(id: UUID) {
    guard canClose(id: id) else { return }
    let wasLastTab = state.panes.count == 1
    closePane(id: id)
    if wasLastTab {
      requestComposerFocus?()
    } else {
      requestSelectedPaneFocus()
    }
  }

  var selectedPane: (any Pane)? {
    state.selectedPane.map(pane(for:))
  }

  @discardableResult
  func reconcileExternalState(_ incoming: PaneGroupState) -> Bool {
    let previousById = Dictionary(uniqueKeysWithValues: state.panes.map { ($0.id, $0) })
    var reconciled = state
    guard reconciled.reconcilePaneDescriptors(from: incoming) else { return false }
    let nextById = Dictionary(uniqueKeysWithValues: reconciled.panes.map { ($0.id, $0) })
    var invalidatedLiveIds = Set<UUID>()

    for id in Array(live.keys) {
      guard let previous = previousById[id], let next = nextById[id] else {
        discardLivePane(id: id)
        invalidatedLiveIds.insert(id)
        continue
      }
      if Self.requiresNewLivePane(previous: previous, next: next) {
        discardLivePane(id: id)
        invalidatedLiveIds.insert(id)
      } else if let sharing = live[id] as? ScreenSharingPane {
        sharing.applyPreferences(next.screenSharing ?? .init())
      } else if let review = live[id] as? ReviewPane {
        review.model.apply(next.review ?? .init())
      } else if let simulator = live[id] as? AppleSimulatorPane {
        simulator.applyPreferences(next.simulator ?? .init())
      }
    }

    let previousSelectedId = state.selectedPaneId
    state = reconciled
    if let previousSelectedId,
      previousSelectedId != state.selectedPaneId,
      let previous = live[previousSelectedId]
    {
      previous.visibilityChanged(false)
    }
    if previousSelectedId != state.selectedPaneId
      || state.selectedPaneId.map({ invalidatedLiveIds.contains($0) }) == true
    {
      selectedPane?.visibilityChanged(true)
    }
    return true
  }

  var canFocusSelectedPane: Bool {
    isFocusCurrent?() ?? true
  }

  func focusSelectedPane() {
    guard canFocusSelectedPane, let id = state.selectedPaneId else { return }
    live[id]?.focus()
  }

  func requestSelectedPaneFocus() {
    guard let id = state.selectedPaneId else { return }
    deferredFocus.request(
      isCurrent: { [weak self] in
        self?.state.selectedPaneId == id && self?.canFocusSelectedPane == true
      },
      focus: { [weak self] in
        guard let self, self.presentedPaneIDs.contains(id), self.live[id] != nil else { return false }
        self.focusSelectedPane()
        return true
      }
    )
  }

  func paneContentDidMount(id: UUID) {
    presentedPaneIDs.insert(id)
    if state.selectedPaneId == id, canFocusSelectedPane { requestSelectedPaneFocus() }
  }

  func detachAll() {
    for pane in live.values {
      pane.detach()
    }
    live.removeAll()
    presentedPaneIDs.removeAll()
    deferredFocus.cancel()
  }

  func persist() {
    repository.save(state, sessionId: sessionId)
  }

  func discardLivePane(id: UUID) {
    presentedPaneIDs.remove(id)
    guard let pane = live.removeValue(forKey: id) else { return }
    pane.visibilityChanged(false)
    pane.detach()
  }

  static func requiresNewLivePane(
    previous: PaneDescriptorState,
    next: PaneDescriptorState
  ) -> Bool {
    switch (previous.kind, next.kind) {
    case (.chat, .chat), (.chat, .newTab), (.newTab, .chat), (.newTab, .newTab):
      return false
    case (.terminal, .terminal):
      return previous.terminalKey != next.terminalKey
    case (.plugin, .plugin):
      return previous.pluginId != next.pluginId
        || previous.pluginPaneType != next.pluginPaneType
    case (.screenSharing, .screenSharing):
      return false
    case (.browser, .browser), (.review, .review), (.simulator, .simulator):
      return false
    case (.document, .document):
      return previous.documentPath != next.documentPath
    default:
      return true
    }
  }
}

extension PaneGroupModel {
  func retarget(
    pluginIconClient: (any CodevisorServerClienting)?,
    pluginIconCacheNamespace: String,
    makeContext: @escaping (PaneDescriptorState) -> PaneContext
  ) {
    self.pluginIconClient = pluginIconClient
    self.pluginIconCacheNamespace = pluginIconCacheNamespace
    self.makeContext = makeContext
    for pane in state.panes where !(live[pane.id] is ChatPane) {
      discardLivePane(id: pane.id)
    }
  }
}
