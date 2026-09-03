import Foundation
import Observation
import CodevisorCore
import ACPKit

/// What the sidebar asks a workspace's mounted container to do with its
/// top tabs. The sidebar cannot act on tabs itself: a terminal or New Tab
/// row has no chat to route through, and closing a tab runs the container's
/// pane-close machinery (archiving chats, evicting leaves).
struct CenterTabRequest: Equatable {
  enum Action: Equatable {
    case select(UUID)
    case close(UUID)
    case new
    /// A pane row: the split leaf to bring forward (its tab comes along).
    case selectLeaf(UUID)
    case closeLeaf(UUID)
  }

  let workspaceId: UUID
  let action: Action
}

/// Caches one `SessionController` per session id so an in-flight conversation
/// survives navigation (e.g. the new-chat → session handoff) and re-selecting a
/// session in the sidebar.
@MainActor
@Observable
final class SessionStore {
  struct SessionKey: Hashable {
    let serverId: String
    let sessionId: UUID

    init(serverId: String, sessionId: UUID) {
      self.serverId = serverId
      self.sessionId = sessionId
    }

    init(_ session: ChatSession) {
      self.init(serverId: session.serverId, sessionId: session.id)
    }
  }

  /// Identity cache, not presentation state. Views resolve controllers while
  /// constructing pane trees; tracking cache insertion would invalidate the
  /// AttributeGraph from inside that same render pass. The controllers are
  /// observable themselves, while `activityRevision` covers aggregate reads.
  @ObservationIgnored var controllers: [SessionKey: SessionController] = [:]
  /// Tiny viewport snapshots share the controller cache's lifetime. This
  /// restores an exact position while its transcript remains resident, while
  /// a genuinely uncached chat opens at the latest content after reloading.
  /// Observation is intentionally disabled: scroll ticks must never
  /// invalidate the store's sidebar/session observers.
  @ObservationIgnored var scrollStates: [SessionKey: SessionScrollState] = [:]
  /// Recent chats retain their mounted native transcript window in addition
  /// to model and geometry state. This is deliberately observation-ignored:
  /// resolving a pane's presentation surface must remain an identity lookup,
  /// not invalidate every session view.
  @ObservationIgnored var transcriptSurfaces =
    TranscriptPresentationSurfaceCache()
  /// Per-session todo-panel expansion deliberately outlives controller
  /// eviction so pinned checklists retain their disclosure state.
  @ObservationIgnored var todoExpansionStates: [SessionKey: Bool] = [:]
  /// Bottom-panel models by WORKSPACE (the panel belongs to the
  /// workspace, and its chats share one detail container — a per-session
  /// key would mint duplicate models over the same persisted group).
  @ObservationIgnored var bottomGroups: [UUID: PaneGroupModel] = [:]
  /// Center-tree leaf groups, keyed by (workspace, leaf group) — the ONE
  /// model per leaf that both the top bar and the split view share.
  struct CenterLeafKey: Hashable {
    let workspaceId: UUID
    let groupId: UUID
  }
  @ObservationIgnored var centerLeafGroups: [CenterLeafKey: PaneGroupModel] = [:]
  /// One live unsent new-chat draft per machine, mirrored to disk by
  /// `ComposerDraftStore`. A controller permanently owns the server client
  /// it was created with, so reusing a draft after a machine switch can send
  /// the new machine's project id to the old server.
  @ObservationIgnored var draftsByServer: [String: SessionController] = [:]
  /// One draft controller per DRAFT CHAT PANE (the in-workspace new-chat
  /// composer), keyed by pane id. Promoted to the session cache on first
  /// send; discarded when the pane closes unsent.
  @ObservationIgnored var paneDrafts: [UUID: SessionController] = [:]
  /// Invalidates views that observe aggregate activity across the cached
  /// controllers. A turn can finish without otherwise mutating this store
  /// (most notably when its session is open), so nested controller
  /// observation alone can leave cross-session UI such as update banners
  /// holding onto its previous value.
  var activityRevision = 0
  /// The session selected by navigation. It is used for controller
  /// retention, never as proof that content was read.
  var openSessionKey: SessionKey?
  /// The chat pane facing the user in this window: the selected chat pane
  /// of the active split leaf. Combined with window key state below, this
  /// is what the app-wide attention coordinator treats as "focused" — the
  /// chat it marks read.
  var focusedChatKey: SessionKey?
  /// Whether this store's window is key. A selected chat behind Settings or
  /// another Codevisor window is not the focused chat.
  var isWindowFocused = false
  /// Bumped by a mounted workspace container after it writes workspace
  /// LAYOUT (tabs added/closed/moved/selected). The repository is not
  /// observable; this is how the sidebar's Nous mode — which renders those
  /// tabs as rows — learns to re-read.
  var workspaceLayoutRevision = 0
  /// A sidebar-originated tab instruction for one workspace's container
  /// (Nous mode). Consumed by that container: through its routing task
  /// when it mounts, or immediately when it is already on screen.
  var centerTabRequest: CenterTabRequest?
  /// Nous: ⇧⌘[ / ⇧⌘] step through the sidebar's flat pane list, across
  /// workspaces. Installed by the docked sidebar (which owns that order
  /// and the route change); returns false when it cannot answer, and the
  /// container falls back to cycling its own tabs.
  @ObservationIgnored var nousStepHandler: ((Int) -> Bool)?
  /// Session ids in access order, most recent last — drives controller
  /// eviction so browsing many sessions doesn't accumulate every transcript
  /// ever opened (conversations retain full tool outputs and diffs).
  /// OBSERVATION-IGNORED, deliberately: `controller(for:)` bumps this
  /// during view bodies (each chat pane resolves its controller there), and
  /// an observed write per body evaluation makes two chat panes invalidate
  /// each other forever — a main-thread render loop (beachball). No view
  /// reads it; it's pure LRU bookkeeping.
  @ObservationIgnored var accessOrder: [SessionKey] = []
  /// How many idle (not open, not working, no background tasks/goal)
  /// controllers stay cached before the least-recently-used are evicted.
  static let maxIdleControllers = 12
  // Internal so split-off extension files (workspace helpers) reach it.
  let environment: AppEnvironment
  let notificationDelivery: any ChatNotificationDelivering

  init(
    environment: AppEnvironment,
    notificationDelivery: (any ChatNotificationDelivering)? = nil
  ) {
    self.environment = environment
    self.notificationDelivery = notificationDelivery ?? ChatNotificationManager.shared
    environment.onMachineRouteChanged = { [weak self] machineId in
      self?.rerouteControllers(on: machineId)
    }
  }

  /// A route flip (direct ↔ relay) leaves cached controllers streaming
  /// over a dead transport. Re-home each affected chat onto a client
  /// resolved over the new route. A connected chat keeps its model and
  /// resumes its stream from the last applied cursor; tearing it down and
  /// replaying history here rewound streaming transcripts to an older
  /// snapshot and re-typed them on every flip.
  func rerouteControllers(on machineId: String) {
    for (key, controller) in controllers where key.serverId == machineId {
      let client = environment.machines.client(for: machineId)
      Task { await controller.rehome(with: client) }
    }
    // Drafts have no live stream, but their next send must ride the new
    // route too.
    for controller in draftsByServer.values
    where controller.project.serverId == machineId {
      controller.adoptServerClient(environment.machines.client(for: machineId))
    }
  }

  /// Returns the cached controller for a session, creating + configuring it
  /// (resume id, harness, persistence callback) if needed.
  func controller(for session: ChatSession, project: Project) -> SessionController {
    let key = SessionKey(session)
    // Registration is the durable draft -> live boundary. A first send
    // registers its controller before the server has produced an agent
    // session id, so it must win over the fallback inference below. If the
    // pane-draft check runs first, the newly bound chat briefly receives a
    // second empty controller and its optimistic row appears only when the
    // agent id later forces lookup back through this cache.
    if let existing = controllers[key] {
      noteAccess(key)
      // Cached lookup runs during view construction and must remain a
      // pure identity read. Observed controller state is reconciled by
      // explicit post-render lifecycle callbacks below.
      return existing
    }

    // A New Chat chosen from an in-workspace placeholder gets a durable
    // session record before its first send, but its live configuration
    // still belongs to the pane draft UNTIL that controller is registered.
    // Reuse (or create) that exact controller here. Minting an ordinary
    // session controller would seed it from the harness default and let
    // focus routing overwrite the workspace profile before the draft
    // composer appears.
    if session.agentSessionId?.isEmpty != false,
      let location = paneDraftLocation(for: session)
    {
      return paneDraft(
        paneId: location.paneId,
        project: project,
        preCreatedSession: session,
        workspaceId: location.workspaceId
      )
    }

    noteAccess(key)
    let workspaceId = environment.workspaces.workspaceId(forSession: session.id)
    let controller = SessionController(
      project: project,
      configCache: environment.configCache,
      composerDefaults: workspaceId == nil ? nil : environment.composerDefaults,
      composerDefaultsScope: workspaceId.map {
        .workspace(id: $0, serverId: session.serverId)
      },
      serverClient: environment.machines.client(for: session.serverId),
      notificationDelivery: notificationDelivery
    )
    controller.configureExistingSession(session)
    controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
      projectList?.setAgentSessionId(
        agentSessionId,
        for: session.id,
        serverId: session.serverId
      )
    }
    controller.scrollState = scrollStates[key]
    controller.onScrollStateChange = { [weak self] state in
      self?.scrollStates[key] = state
    }
    controller.restoreTodoDisclosure(
      isExpanded: todoExpansionStates[key] ?? false
    )
    controller.onTodosExpandedChange = { [weak self] isExpanded in
      self?.todoExpansionStates[key] = isExpanded
    }
    controller.onTurnEnded = { [weak self] in self?.noteTurnEnded() }
    controllers[key] = controller
    return controller
  }

  /// Returns the pane-specific native transcript presentation. Including the
  /// pane id lets the same chat appear in two splits without one AppKit view
  /// being stolen back and forth between them.
  func transcriptSurface(
    for session: ChatSession,
    paneID: UUID,
    controller: SessionController
  ) -> TranscriptPresentationSurface {
    transcriptSurfaces.surface(
      for: .init(
        serverID: session.serverId,
        sessionID: session.id,
        paneID: paneID
      ),
      controller: controller
    )
  }

  /// Reconciles a controller after view construction (or from an explicit
  /// event callback). The identity guard prevents a stale view from writing
  /// into a controller that has since been replaced or evicted.
  func reconcile(
    _ controller: SessionController,
    for session: ChatSession,
    project: Project
  ) {
    guard activeController(for: session) === controller else { return }
    if controller.project != project {
      controller.project = project
    }
    controller.reconcileExistingSession(session)
  }

  /// The live controller for a session WITHOUT creating one — a pure read,
  /// safe in view bodies. For an eagerly-created unsent chat this is its
  /// pane-draft controller, not a second generic session controller.
  func activeController(for session: ChatSession) -> SessionController? {
    if let controller = controllers[SessionKey(session)] {
      return controller
    }
    guard session.agentSessionId?.isEmpty != false,
      let location = paneDraftLocation(for: session)
    else { return nil }
    return paneDrafts[location.paneId]
  }

  /// Stand-in workspaces for chats mid-teardown (see `workspace(for:)`);
  /// cached so repeated body evaluations see one stable identity.
  @ObservationIgnored var ephemeralWorkspaces: [UUID: Workspace] = [:]

  // MARK: - Unread badges

  // MARK: - Eviction

}
