//  The live pane group for one chat session: owns the persisted PaneGroupState
//  (panes and selection), lazily instantiates live Pane objects
//  from their descriptors, fires the pane lifecycle hooks, and persists every
//  state mutation.

import Autocomplete
import Foundation
import Observation
import SwiftUI
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI

@MainActor
@Observable
final class PaneGroupModel: Identifiable {
  /// The chat session this group belongs to, or nil when the group's identity
  /// comes from its workspace instead (a workspace that has never hosted a
  /// chat). Nothing substitutes another id here: a nil session means features
  /// that need a real session identity are unavailable, not renamed. It becomes
  /// non-nil exactly once, through `adoptSession`, when a real chat appears in
  /// this leaf.
  private(set) var sessionId: UUID?
  var state: PaneGroupState
  /// Builds a chat pane's content from its LIVE descriptor (drafts render
  /// the new-chat composer; established chats their session's ChatScreen).
  /// Wired by the container at model creation — before anything renders —
  /// so it needs no observability (and is set during body evaluation,
  /// where observable mutation would be illegal).
  @ObservationIgnored var chatContent: ((PaneDescriptorState) -> AnyView)?

  @ObservationIgnored var live: [UUID: any Pane] = [:]
  @ObservationIgnored private let repository: any PaneGroupRepository
  /// Rebuilt by `adoptSession` so panes created after a chat appears get the
  /// chat-anchored context instead of the workspace-only one.
  @ObservationIgnored private var makeContext: (PaneDescriptorState) -> PaneContext
  @ObservationIgnored let pluginIconClient: (any CodevisorServerClienting)?
  @ObservationIgnored let pluginIconCacheNamespace: String
  /// Set by the workspace container: moves keyboard focus to the composer (used
  /// as the chat pane's focus target).
  @ObservationIgnored var requestComposerFocus: (() -> Void)?
  /// Set by the workspace container: clears focus from another pane without
  /// inventing an input target for content that has none (currently the
  /// New Tab placeholder). This keeps a hidden terminal from remaining the
  /// first responder after its tab is replaced by a passive page.
  @ObservationIgnored var requestBackgroundFocus: (() -> Void)?
  /// New Tab pages register where keyboard focus should go when their pane
  /// is focused (their picker's input). Without one, the pane falls back to
  /// neutral background focus.
  @ObservationIgnored private var newTabFocusHandlers: [UUID: () -> Void] = [:]
  /// A New Tab pane that was focused before its page registered (⌘T focuses
  /// the new pane a run-loop turn after adding it, ahead of the page's
  /// mount). Replayed when the handler arrives.
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
  /// Fired after a tab closes (the descriptor already removed) — the app
  /// layer cleans up per-pane resources (draft controllers) and archives
  /// closed established chats' sessions.
  @ObservationIgnored var onPaneClosed: ((PaneDescriptorState) -> Void)?
  /// Shared identity changed (create/convert/rename/bind). Layout persistence
  /// stays local; the owning store mirrors this descriptor to the server.
  @ObservationIgnored var onPaneChanged: ((PaneDescriptorState) -> Void)?
  /// Separate from `onPaneClosed`, which containers replace with navigation
  /// policy. A non-nil replacement means this was the workspace's final
  /// pane and the same shared identity was optimistically reset to New Tab.
  @ObservationIgnored var onPaneRemoved: ((PaneDescriptorState, PaneDescriptorState?) -> Void)?
  /// Workspace-wide final-pane policy supplied by the owning store.
  @ObservationIgnored var shouldReplaceClosedPaneWithNewTab: ((PaneDescriptorState) -> Bool)?
  /// Whether this group may dissolve out of the workspace (i.e. other
  /// groups exist). Gates closing a LONE New Tab placeholder — its close
  /// IS a dissolve, and in the workspace's last group it would just
  /// respawn. Nil (previews) means no.
  @ObservationIgnored var canDissolve: (() -> Bool)?
  /// Fired whenever the user acts IN this group (tab click, pane focus,
  /// new tab, adopted drop) — the container tracks the workspace's ACTIVE
  /// group with it, which is where keyboard tab commands route.
  @ObservationIgnored var onActivated: (() -> Void)?
  /// Programmatic focus may only follow the window's committed destination.
  @ObservationIgnored var isFocusCurrent: (() -> Bool)?
  @ObservationIgnored let deferredFocus = DeferredPaneFocus()
  @ObservationIgnored var presentedPaneIDs: Set<UUID> = []
  /// Center leaves hand workspace-level tab/split commands to their
  /// container. Returning true means the command was consumed.
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
      // Persist the initial pane identity before mounting its content.
      let initial =
        sessionId.map { PaneGroupState.centerInitial(sessionId: $0) }
        ?? .centerInitialWithoutChat()
      self.state = initial
      repository.save(initial, sessionId: sessionId)
    }
    ChromiumAutomationBridge.shared.addGroup(self)
  }

  /// Binds this group to the chat that now exists in its workspace. Groups are
  /// cached per workspace+leaf, so the model the user created a chat in is the
  /// same object that later hosts it: without this it would keep a nil identity
  /// and leave terminals, browser automation and file-backed panes unavailable
  /// forever. Live panes are preserved; only those whose content depended on
  /// the missing session are dropped so they rebuild against the real one.
  /// Adoption happens once — an existing identity is never re-pointed.
  func adoptSession(
    _ sessionId: UUID,
    makeContext: @escaping (PaneDescriptorState) -> PaneContext
  ) {
    guard self.sessionId == nil else { return }
    self.sessionId = sessionId
    self.makeContext = makeContext
    for pane in state.panes where pane.kind == .document {
      discardLivePane(id: pane.id)
    }
  }

  func canHostBrowserAutomation(sessionId requested: String) -> Bool {
    guard createBrowserTab != nil, let descriptor = state.panes.first,
      makeContext(descriptor).machine.isLocal
    else { return false }
    // Both sides compare ACTUAL session identities: a group without one simply
    // never matches on its own id, and can still host automation for a real
    // chat pane living inside it.
    return sessionId?.uuidString.lowercased() == requested.lowercased()
      || state.panes.contains { $0.chatSessionId?.uuidString.lowercased() == requested.lowercased() }
  }

  /// Browser automation creates workspace tabs, not another selection inside
  /// this leaf. The store owns the workspace and publishes the new pane.
  @ObservationIgnored var createBrowserTab: ((String) -> ChromiumBrowserModel?)?
  @ObservationIgnored var openBrowserLink: ((UUID, String, BrowserLinkDestination, CVChromiumView?) -> Bool)?

  // MARK: - Live panes

  func openFiles(id: UUID) {
    guard let index = state.panes.firstIndex(where: { $0.id == id }) else { return }
    let context = makeContext(state.panes[index])
    let root = context.workspaceRootDirectory ?? context.session?.cwd ?? context.project.folderURL.path
    let pane = PaneDescriptorState(
      id: id, kind: .document, name: "Files", terminalKey: id.uuidString, documentPath: root + "/")
    discardLivePane(id: id)
    state.panes[index] = pane
    persist()
    onPaneChanged?(pane)
  }

  /// The live pane for a descriptor, built on first use. New pane kinds add
  /// a factory branch here.
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
      let document = FilePane(context: makeContext(descriptor), descriptor: descriptor)
      document.onNavigate = { [weak self] path in
        guard let self, let index = state.panes.firstIndex(where: { $0.id == descriptor.id }) else { return }
        state.panes[index].documentPath = path
        state.panes[index].name = FileDocumentLocation.name(path)
        persist()
        onPaneChanged?(state.panes[index])
      }
      pane = document
    case .terminal:
      let terminal = TerminalPane(context: makeContext(descriptor))
      terminal.onContentAttached = { [weak self] in self?.requestSelectedPaneFocus() }
      pane = terminal
    case .plugin:
      let plugin = PluginPane(context: makeContext(descriptor), descriptor: descriptor)
      // `codevisor.setTitle` renames the pane's tab like a manual
      // rename would (persisted + published).
      plugin.onTitleChange = { [weak self] title in
        self?.renamePane(id: descriptor.id, to: title)
      }
      pane = plugin
    // The New Tab placeholder rides the chat pane's plumbing: an
    // AnyView host resolving content from the live descriptor via
    // `chatContent` (the container branches on kind there).
    case .chat, .newTab:
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
    browser.model.onOpenLink = { [weak self, weak browser] url, destination, popup in
      guard let self, let browser else { return false }
      return self.openBrowserLink?(browser.id, url, destination, popup) ?? false
    }
    browser.model.onClose = { [weak self, weak browser] in if let browser { self?.closePane(id: browser.id) } }
    browser.model.onSelect = { [weak self, weak browser] in if let browser { self?.select(id: browser.id) } }
    browser.model.onNavigate = { [weak self, weak browser] url, title in
      guard let self, let browser,
        let index = self.state.panes.firstIndex(where: { $0.id == browser.id }),
        self.state.panes[index].browserURL != url || self.state.panes[index].name != title
      else { return }
      self.state.panes[index].browserURL = url
      self.state.panes[index].name = title
      self.persist()
      self.onPaneChanged?(self.state.panes[index])
    }
  }

  /// Binds a ChatPane host to THIS group: content resolves from the LIVE
  /// descriptor on every render (a draft transmutes into its session's
  /// chat the moment first-send binds it). Called at creation AND on
  /// adoption — a pane moved from another group carries a provider bound
  /// to its OLD model, whose descriptor lookup fails (the pane left) and
  /// renders nothing.
  func wireChatHost(_ chat: ChatPane, paneId: UUID) {
    // Chat panes hand focus to their composer. A New Tab placeholder has
    // no editor, but still needs a neutral focus target so selecting it
    // releases a terminal or another panel's controls.
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
      case .terminal, .plugin, .document, .browser, .screenSharing:
        break
      }
    }
    chat.contentProvider = { [weak self, paneId] in
      guard let self,
        let current = self.state.panes.first(where: { $0.id == paneId }),
        let content = self.chatContent
      else { return AnyView(EmptyView()) }
      return content(current)
    }
  }

  func paneFocusChanged(focused: Bool) {
    if focused { onActivated?() }
  }

  /// Keyboard shortcuts forwarded from a focused pane. Center leaves first
  /// offer them to the workspace container before handling them locally.
  func handleCommand(_ command: PaneGroupCommand) {
    if workspaceCommandHandler?(command) == true { return }
    switch command {
    case .newTab:
      addNewTabPane()
      requestSelectedPaneFocus()
    case .nextTab, .previousTab:
      let panes = state.panes
      guard panes.count > 1,
        let index = panes.firstIndex(where: { $0.id == state.selectedPaneId })
      else { return }
      let step: Int = if case .nextTab = command { 1 } else { -1 }
      let target = panes[(index + step + panes.count) % panes.count]
      select(id: target.id)
      requestSelectedPaneFocus()
    case .selectTab(let index):
      guard state.panes.indices.contains(index) else { return }
      select(id: state.panes[index].id)
      requestSelectedPaneFocus()
    case .split, .focusSplit, .previousSplit, .nextSplit, .reopenClosedPane:
      return
    case .closeTab:
      guard let selected = state.selectedPane,
        canClose(id: selected.id)
      else { return }
      let wasLastTab = state.panes.count == 1
      closePane(id: selected.id)
      if wasLastTab {
        // The leaf is now empty; hand focus back.
        requestComposerFocus?()
      } else {
        requestSelectedPaneFocus()
      }
    }
  }

  var selectedPane: (any Pane)? {
    state.selectedPane.map(pane(for:))
  }

  /// Applies pane content reconciled from the shared workspace registry to
  /// this mounted group without treating it as a local edit. In particular,
  /// this does not persist or call `onPaneChanged`/`onPaneRemoved`: the
  /// repository already contains the reconciled state and echoing it would
  /// turn an inbound server snapshot into another outbound mutation.
  ///
  /// New Tab and chat share the same live host, so their in-place promotion
  /// keeps focus and view identity. Renderer changes that need a different
  /// host discard only that pane's live object and rebuild lazily.
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

  /// Focus is an effect of navigation, never another selection command.
  /// Resolve only an already mounted pane: focus must not create a terminal
  /// surface, browser, plugin webview, or chat controller on the key path.
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

  /// App-side teardown for all live panes (backing shells survive on the
  /// server — app-quit semantics).
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
      // ChatPane resolves the current descriptor on every render.
      return false
    case (.terminal, .terminal):
      // TerminalPane captures connection identity in its PaneContext.
      return previous.terminalKey != next.terminalKey
        || previous.attachOnly != next.attachOnly
    case (.plugin, .plugin):
      // PluginPane captures the plugin identity at creation; a pane
      // re-pointed at another plugin/pane type needs a fresh webview.
      return previous.pluginId != next.pluginId
        || previous.pluginPaneType != next.pluginPaneType
    case (.screenSharing, .screenSharing):
      return false
    case (.browser, .browser):
      return false
    case (.document, .document):
      return previous.documentPath != next.documentPath
    default:
      return true
    }
  }
}
