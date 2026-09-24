import Foundation
import Testing
@testable import CodevisorCore

struct HomeNavigationStateTests {
  private let workspaceId = UUID()
  private let sessionId = UUID()
  private let paneId = UUID()
  private let generation = UUID()

  private func workspaceRoute(
    anchor: UUID? = nil, chat: UUID? = nil, pane: UUID? = nil
  ) -> HomeRoute {
    .workspace(
      serverId: "machine", workspaceId: workspaceId, anchorSessionId: anchor,
      preferredChatSessionId: chat, preferredPaneId: pane
    )
  }

  @Test("An empty path reads as New Chat on the home page")
  func emptyIsNewChat() {
    let state = HomeNavigationState()
    #expect(state.selection == nil)
    #expect(state.isNewChatSelected)
    #expect(state.clientPage == "home")
    #expect(state.presentedWorkspace == nil)
    #expect(state.detailRoute(fallbackServerId: "m") == .newChat(serverId: "m"))
    #expect(state.detailIdentity(promotedDraftSessionId: nil, draftGeneration: generation) == .draft(generation))
  }

  @Test("Opening pushes on a stack and replaces on a split")
  func openPerMode() {
    var stack = HomeNavigationState(path: [.newChat(serverId: nil)])
    stack.open(workspaceRoute(), mode: .stack)
    #expect(stack.path.count == 2)
    #expect(stack.clientPage == "workspace")

    var split = HomeNavigationState(path: [.newChat(serverId: nil)])
    split.open(workspaceRoute(), mode: .split)
    #expect(split.path == [workspaceRoute()])
    #expect(!split.isNewChatSelected)
  }

  @Test("Select, replaceTop, and popToRoot keep a single-entry model")
  func selectionMutations() {
    var state = HomeNavigationState()
    state.replaceTop(with: .newChat(serverId: "m"))
    #expect(state.path == [.newChat(serverId: "m")])
    #expect(state.clientPage == "new_chat")

    state.replaceTop(with: workspaceRoute(anchor: sessionId))
    #expect(state.path == [workspaceRoute(anchor: sessionId)])
    #expect(state.presentedWorkspace?.workspaceId == workspaceId)
    #expect(state.presentedWorkspace?.anchorSessionId == sessionId)

    state.select(nil)
    #expect(state.path.isEmpty)
    state.select(workspaceRoute())
    state.popToRoot()
    #expect(state.path.isEmpty)
  }

  @Test("A promoted draft keeps the draft identity; other workspaces do not")
  func detailIdentityThroughPromotion() {
    var state = HomeNavigationState(path: [.newChat(serverId: nil)])
    #expect(state.detailIdentity(promotedDraftSessionId: nil, draftGeneration: generation) == .draft(generation))

    state.replaceTop(with: workspaceRoute(anchor: sessionId, chat: sessionId))
    #expect(state.detailIdentity(promotedDraftSessionId: sessionId, draftGeneration: generation) == .draft(generation))
    #expect(state.detailIdentity(promotedDraftSessionId: nil, draftGeneration: generation) == .workspace(workspaceId))
    #expect(
      state.detailIdentity(promotedDraftSessionId: UUID(), draftGeneration: generation) == .workspace(workspaceId))

    // A fresh draft after the promotion must not share the promoted identity.
    state.select(nil)
    let next = UUID()
    #expect(state.detailIdentity(promotedDraftSessionId: sessionId, draftGeneration: next) == .draft(next))
    #expect(state.detailIdentity(promotedDraftSessionId: sessionId, draftGeneration: next) != .draft(generation))
  }

  @Test("The highlighted sidebar row follows the pane, then the chat")
  func selectedPane() {
    let chatPane = UUID()
    let byPane = HomeNavigationState(path: [workspaceRoute(anchor: sessionId, pane: paneId)])
    #expect(byPane.selectedPaneId { _ in chatPane } == paneId)

    let byChat = HomeNavigationState(path: [workspaceRoute(anchor: UUID(), chat: sessionId)])
    #expect(byChat.selectedPaneId { $0 == sessionId ? chatPane : nil } == chatPane)

    let byAnchor = HomeNavigationState(path: [workspaceRoute(anchor: sessionId)])
    #expect(byAnchor.selectedPaneId { $0 == sessionId ? chatPane : nil } == chatPane)

    #expect(HomeNavigationState().selectedPaneId { _ in chatPane } == nil)
  }

  @Test("Following the workspace's own pane selection canonicalizes the route")
  func followPaneSelectionCanonicalizes() {
    // A chat opened from the sidebar routes by chat, not by pane.
    var state = HomeNavigationState(path: [workspaceRoute(anchor: sessionId, chat: sessionId)])
    let chatPane = UUID()

    let followed = state.followPaneSelection(workspaceId: workspaceId, paneId: chatPane)
    #expect(followed)
    #expect(state.selection == workspaceRoute(anchor: sessionId, pane: chatPane))
    // The anchor survives: it owns the detail's identity and its controller.
    #expect(state.presentedWorkspace?.anchorSessionId == sessionId)

    // Already canonical: no write, so the detail is not re-rendered.
    let again = state.followPaneSelection(workspaceId: workspaceId, paneId: chatPane)
    #expect(!again)
  }

  @Test("A New Tab the workspace opened itself leaves the chat row tappable")
  func followPaneSelectionKeepsSidebarTapsLive() {
    let chatPane = UUID()
    let terminalPane = UUID()
    var state = HomeNavigationState(path: [workspaceRoute(anchor: sessionId, chat: sessionId)])
    state.followPaneSelection(workspaceId: workspaceId, paneId: chatPane)

    // New Tab moves the workspace's selection without touching the route.
    // Following it is what keeps the route honest.
    let followed = state.followPaneSelection(workspaceId: workspaceId, paneId: terminalPane)
    #expect(followed)
    #expect(state.selection == workspaceRoute(anchor: sessionId, pane: terminalPane))

    // Tapping the chat row again must now be a real change, or the detail —
    // which switches panes only when the route changes — would ignore it.
    #expect(state.selection != workspaceRoute(anchor: sessionId, chat: sessionId))
  }

  @Test("A selection from another workspace or page never moves the route")
  func followPaneSelectionIgnoresForeignSelections() {
    let route = workspaceRoute(anchor: sessionId, pane: paneId)
    var state = HomeNavigationState(path: [route])
    let foreign = state.followPaneSelection(workspaceId: UUID(), paneId: UUID())
    #expect(!foreign)
    #expect(state.selection == route)

    var draft = HomeNavigationState(path: [.newChat(serverId: "m")])
    let onDraft = draft.followPaneSelection(workspaceId: workspaceId, paneId: paneId)
    #expect(!onDraft)
    #expect(draft.selection == .newChat(serverId: "m"))

    var empty = HomeNavigationState()
    let onEmpty = empty.followPaneSelection(workspaceId: workspaceId, paneId: paneId)
    #expect(!onEmpty)
    #expect(empty.path.isEmpty)
  }

  @Test("Following the selection replaces the top rather than deepening a stack")
  func followPaneSelectionKeepsDepth() {
    var state = HomeNavigationState(path: [.newChat(serverId: "m"), workspaceRoute(anchor: sessionId)])
    let followed = state.followPaneSelection(workspaceId: workspaceId, paneId: paneId)
    #expect(followed)
    #expect(state.path.count == 2)
    #expect(state.path.first == .newChat(serverId: "m"))
    #expect(state.selection == workspaceRoute(anchor: sessionId, pane: paneId))
  }

  @Test("Unfolding with a composing sheet continues the draft as the page")
  func stackToSplitWithSheet() {
    let transition = HomeNavigationState.layoutTransition(
      from: .stack, to: .split, path: [], composingSheet: true, sheetServerId: "m"
    )
    #expect(transition.path == [.newChat(serverId: "m")])
    #expect(transition.dismissesNewChatSheet)
    #expect(transition.requestsComposerFocus)
  }

  @Test("Unfolding without a sheet keeps only the top of the stack")
  func stackToSplitWithoutSheet() {
    let top = workspaceRoute(anchor: sessionId)
    let transition = HomeNavigationState.layoutTransition(
      from: .stack, to: .split, path: [.newChat(serverId: nil), top], composingSheet: false
    )
    #expect(transition.path == [top])
    #expect(!transition.dismissesNewChatSheet)
    #expect(!transition.requestsComposerFocus)
  }

  @Test("Folding keeps the path and refocuses only a draft")
  func splitToStack() {
    let draft = HomeNavigationState.layoutTransition(
      from: .split, to: .stack, path: [.newChat(serverId: nil)], composingSheet: false
    )
    #expect(draft.path == [.newChat(serverId: nil)])
    #expect(!draft.dismissesNewChatSheet)
    #expect(draft.requestsComposerFocus)

    let workspace = HomeNavigationState.layoutTransition(
      from: .split, to: .stack, path: [workspaceRoute()], composingSheet: false
    )
    #expect(workspace.path == [workspaceRoute()])
    #expect(!workspace.requestsComposerFocus)
  }

  @Test("A same-mode transition is the identity")
  func sameMode() {
    let path = [workspaceRoute()]
    let transition = HomeNavigationState.layoutTransition(
      from: .split, to: .split, path: path, composingSheet: true, sheetServerId: "m"
    )
    #expect(transition == HomeLayoutTransition(path: path, dismissesNewChatSheet: false, requestsComposerFocus: false))
  }
}
