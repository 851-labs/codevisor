import CodevisorCore
import CodevisorUI
import Foundation
import Observation

@Observable
final class WindowNavigation: SidebarSelectionOwner {
  static let keptAlivePages = 5

  let id = UUID()
  let deck = PageDeck<WorkspaceDeckSlot, WorkspaceDeckRoute>(capacity: WindowNavigation.keptAlivePages)
  let deckSizes = WorkspaceDeckSizes()
  let detailFocus = DetailColumnFocusAnchor()

  private var storedSelection: SidebarSelection?
  @ObservationIgnored private var pages: [WorkspaceDeckSlot: WorkspacePageModel] = [:]
  @ObservationIgnored private weak var store: SessionStore?
  @ObservationIgnored private var environment: AppEnvironment?

  var selection: SidebarSelection? {
    get { storedSelection }
    set {
      guard newValue != storedSelection else { return }

      storedSelection = newValue
      markOpened(newValue)
      showDeckPage()
    }
  }

  var deckSlot: WorkspaceDeckSlot? {
    WorkspaceDeckRoute(selection).map(slot(for:))
  }

  var activePage: WorkspacePageModel? {
    deck.activeSlot.map(page(for:))
  }

  func page(for slot: WorkspaceDeckSlot) -> WorkspacePageModel {
    if let page = pages[slot] { return page }

    let page = WorkspacePageModel()
    pages[slot] = page
    return page
  }

  func attach(store: SessionStore, environment: AppEnvironment) {
    self.store = store
    self.environment = environment
    showDeckPage()
  }

  func showDeckPage() {
    guard environment != nil else { return }

    let previous = deck.activeSlot
    guard let route = WorkspaceDeckRoute(storedSelection) else {
      deck.showNothing()
      deckSizes.show(nil, hiding: previous)
      return
    }
    let slot = slot(for: route)
    let focusOwner = detailFocus.focusOwner
    if deck.show(route, in: slot) { NavigationSwitchTrace.shared.note("builtPage") }
    if slot != previous { detailFocus.releaseFocus(heldBy: focusOwner) }
    deckSizes.show(slot, hiding: previous)
    let mounted = Set(deck.pages.map(\.id))
    deckSizes.keep(mounted)
    pages = pages.filter { mounted.contains($0.key) }
  }

  private func slot(for route: WorkspaceDeckRoute) -> WorkspaceDeckSlot {
    guard WorkspaceDeckPolicy.reusesChatPage else { return ownSlot(for: route) }

    if let mounted = deck.pages.first(where: { $0.route == route }) { return mounted.id }
    return showsPlainChat(route) ? .sharedChat : ownSlot(for: route)
  }

  private func showsPlainChat(_ route: WorkspaceDeckRoute) -> Bool {
    guard case let .session(_, sessionId) = route, let environment,
      let workspaceId = environment.workspaces.workspaceId(forSession: sessionId)
    else { return false }

    return environment.navigationStore.workspaceEntries.entry(workspaceId).workspace?.isPlainChat == true
  }

  private func ownSlot(for route: WorkspaceDeckRoute) -> WorkspaceDeckSlot {
    switch route {
    case let .session(_, sessionId):
      environment?.workspaces.workspaceId(forSession: sessionId).map(WorkspaceDeckSlot.workspace) ?? .session(sessionId)
    case let .workspace(_, workspaceId):
      .workspace(workspaceId)
    case let .bot(_, botId):
      .bot(botId)
    }
  }

  private func markOpened(_ selection: SidebarSelection?) {
    guard let store else { return }

    if case let .session(serverId, sessionId) = selection {
      store.markOpened(sessionId, serverId: serverId)
    } else if case let .bot(serverId, botId) = selection,
      let bot = environment?.bots.bot(serverId: serverId, id: botId)
    {
      store.markOpened(bot.sessionId, serverId: serverId)
    } else {
      store.clearOpenSession()
    }
  }
}
