import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// The New Chat sheet, its first-send promotion into a real workspace
/// route, and the canonical workspace destination.
extension HomeView {
  func presentNewChat() {
    newChatSheetPath = NavigationPath()
    let flow = NewChatFlow()
    // Capture the navigation root before SwiftUI begins the native sheet
    // presentation. The promoted NavigationStack uses these exact pixels
    // as its root during an interactive back swipe.
    flow.homeSnapshot = currentHomeSnapshot()
    newChatFlow = flow
    presentedNewChatFlow = flow
  }

  #if DEBUG || NAVIGATION_DIAGNOSTICS
    /// Presents the sheet and, once its draft controller exists, types the
    /// text into it (the composer mirrors model-initiated changes).
    func presentDiagnosticNewChat(text: String) {
      presentNewChat()
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(900))
        let controller = ChatControllerCache.shared.draftController(
          preferredProject: .runTargetPlaceholder(serverId: environment.defaultComposerServerId),
          environment: environment
        )
        controller.composerText = text
        IOSNavigationDiagnostics.record("diag.newChat.prefilled", "chars=\(text.count)")
      }
    }
  #endif

  /// The first send is creating its session: the sheet's bubble may already
  /// be airborne, so the expansion starts here, before the send publishes
  /// the session and workspace and Home re-renders under the sheet.
  private func beginNewChatExpansion(_ flow: NewChatFlow) {
    guard newChatFlow === flow, flow.phase == .composing else { return }
    flow.phase = .animating
    expandPromotionSurfaceIfReady(flow)
  }

  private func beginNewChatPromotion(_ sessionId: UUID, flow: NewChatFlow) {
    guard newChatFlow === flow, flow.sessionId == nil else { return }
    guard
      // Fleet-wide: the draft may have been sent to ANOTHER machine's
      // project (session ids are unique across the fleet).
      let session = projectList.sessions.first(where: { $0.id == sessionId })
    else { return }
    // Deliberately NO machine switch here: the promotion animation is
    // mid-flight, and flipping the selected machine re-renders Home under
    // the snapshot and churns availability. iOS routes carry the
    // session's serverId end to end, so the selected machine simply
    // doesn't need to follow a send.
    flow.sessionId = sessionId
    let workspace = ensureWorkspace(for: session)
    flow.promotionServerId = session.serverId
    flow.promotionWorkspaceId = workspace.id
    flow.phase = .animating
    flow.promotionWatchdog.start { [weak flow] in
      guard let flow else { return }
      finishNewChatPromotionWithoutAnimation(flow, reason: "handoff-timeout")
    }
    IOSNavigationDiagnostics.record(
      "home.newChatPromotion",
      "workspace=\(shortID(workspace.id)) session=\(shortID(sessionId)) pathBefore=\(navigationPathSummary(path))"
    )
    // Normally already under way from `beginNewChatExpansion`; this is the
    // path for a bubble that took off after the session existed.
    expandPromotionSurfaceIfReady(flow)
    // The canonical route's mount is ~300 ms of main-thread work in a debug
    // build. A plain `main.async` would still drain before this turn's
    // commit — the one carrying the expansion — so mount it a frame later,
    // while the animation is already playing.
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak flow] in
      guard let flow else { return }
      pushCanonicalNewChatRoute(flow)
    }
  }

  /// Mounts Home's canonical workspace route. The local send owns the
  /// route; animation only reveals it.
  private func pushCanonicalNewChatRoute(_ flow: NewChatFlow) {
    guard newChatFlow === flow, !flow.didPushCanonicalRoute,
      let sessionId = flow.sessionId,
      let serverId = flow.promotionServerId,
      let workspaceId = flow.promotionWorkspaceId
    else { return }
    flow.didPushCanonicalRoute = true
    path.append(
      .workspace(
        serverId: serverId,
        workspaceId: workspaceId,
        anchorSessionId: sessionId,
        preferredChatSessionId: sessionId
      )
    )
    IOSNavigationDiagnostics.record(
      "home.newChatPromotion.routePushed",
      "path=\(navigationPathSummary(path))"
    )
  }

  /// The resting sheet grows into the full-screen route.
  private static let promotionExpansionDuration: TimeInterval = 0.35

  /// Called once the sheet is presented: builds the (session-independent)
  /// expansion surface and mounts its chrome replica, hidden, after the
  /// sheet's own presentation has settled.
  func prepareNewChatPromotionSurfaceSoon(_ flow: NewChatFlow) {
    Task { @MainActor [weak flow] in
      try? await Task.sleep(for: .milliseconds(700))
      guard let flow else { return }
      prepareNewChatPromotionSurface(flow)
    }
  }

  private func prepareNewChatPromotionSurface(_ flow: NewChatFlow) {
    guard newChatFlow === flow, flow.phase != .settled, flow.promotionSurface == nil,
      // Host the surface in the PRESENTING (main) window, not the sheet's:
      // zoom presentations can put the sheet in a transient portal window
      // whose layer tree detaches from the render server — an animator
      // started there completes instantly, killing the whole morph.
      let presentationWindow = flow.presentationSession?.promotionHostWindow
    else { return }
    let surface = NewChatPromotionSurface(
      window: presentationWindow,
      duration: reduceMotion ? 0 : Self.promotionExpansionDuration,
      editorHandoffID: flow.id,
      liveContent: AnyView(
        NewChatPromotionChromeReplica(
          flow: flow,
          root: AnyView(promotionHomeSnapshot(flow))
        )
        .environment(environment)
      ),
      onExpanded: { [weak flow] in
        guard let flow, newChatFlow === flow else { return }
        flow.didFinishSurfaceAnimation = true
        finishNewChatPromotionIfReady(flow)
      }
    )
    flow.promotionSurface = surface
    surface.prepareReplica()
  }

  private func markFirstSendAnimationStarted(_ flow: NewChatFlow) {
    guard newChatFlow === flow, !flow.didStartFirstSendAnimation else { return }
    IOSNavigationDiagnostics.record("home.newChatPromotion.sheetSendStarted")
    flow.didStartFirstSendAnimation = true
    // Reported from inside the transcript's layout pass: continue on the
    // next turn, never re-entrantly inside layout.
    Task { @MainActor [weak flow] in
      await Task.yield()
      guard let flow, newChatFlow === flow else { return }
      beginPromotionChromeMorph(flow)
      expandPromotionSurfaceIfReady(flow)
    }
  }

  /// The replica's trailing button morphs × into +. SwiftUI applies this
  /// only at the end of a turn — a mid-turn `CATransaction.flush()` does
  /// not run its update — so it goes in this cheap turn, ahead of the
  /// send's session publication whose commit re-renders all of Home. The
  /// bitmap's bar strip still covers the button; its fade reveals the
  /// morph already under way, which reads as the × turning into +.
  private func beginPromotionChromeMorph(_ flow: NewChatFlow) {
    guard !flow.hasStartedExpansion else { return }
    withAnimation(.easeInOut(duration: Self.promotionExpansionDuration + 0.15)) {
      flow.hasStartedExpansion = true
    }
  }

  /// Starts the expansion the moment the bubble is airborne AND the send
  /// is committed to a session — whichever comes second — and commits it
  /// in the same turn. Everything the send does next (publishing the
  /// session, mounting the route, starting the agent) re-renders large
  /// SwiftUI hierarchies; an expansion still waiting on any of those
  /// commits would start a quarter second late and skip its first frames.
  private func expandPromotionSurfaceIfReady(_ flow: NewChatFlow) {
    guard newChatFlow === flow,
      flow.phase == .animating,
      flow.didStartFirstSendAnimation || flow.didFinishFirstSendAnimation,
      let presentationSession = flow.presentationSession
    else { return }
    prepareNewChatPromotionSurface(flow)
    guard let surface = flow.promotionSurface, !surface.didStartExpansion else { return }
    guard let presentationWindow = presentationSession.promotionHostWindow,
      let sourceFrame = presentationSession.visibleFrame(in: presentationWindow)
    else {
      // The watchdog settles a sheet whose geometry never resolves.
      IOSNavigationDiagnostics.record("home.newChatPromotion.expand", "skipped=geometry-missing")
      return
    }
    IOSNavigationDiagnostics.record(
      "home.newChatPromotion.expand", "from=\(NSCoder.string(for: sourceFrame))")
    beginPromotionChromeMorph(flow)
    surface.expand(
      sourceFrame: sourceFrame,
      sourceCornerRadius: presentationSession.presentationCornerRadius,
      snapshot: presentationSession.snapshotImage(),
      barHeight: presentationSession.navigationBarBottom ?? 54,
      composerTop: presentationSession.composerTop,
      runPickersFrame: presentationSession.runPickersFrame
    )
  }

  private func markPromotedWorkspaceReady(_ sessionId: UUID) {
    guard let flow = newChatFlow, flow.sessionId == sessionId else { return }
    flow.isWorkspaceReady = true
    finishNewChatPromotionIfReady(flow)
  }

  private func markFirstSendAnimationCompleted(
    _: UserSendAnimationRequest,
    flow: NewChatFlow
  ) {
    guard newChatFlow === flow else { return }
    IOSNavigationDiagnostics.record("home.newChatPromotion.sheetSendSettled")
    flow.didFinishFirstSendAnimation = true
    // Fallback ordering (reduce motion, an instant flight): this arrives
    // from the transcript's Core Animation completion, inside a transaction
    // with implicit actions disabled, so expand on the next turn.
    Task { @MainActor [weak flow] in
      await Task.yield()
      guard let flow else { return }
      expandPromotionSurfaceIfReady(flow)
    }
    finishNewChatPromotionIfReady(flow)
  }

  /// Destination construction is deliberately read-only. Normal row taps
  /// populate the cache before pushing, while promoted drafts are registered
  /// there before this route appears.
  func workspaceDestination(
    serverId: String,
    workspaceId: UUID,
    anchorSessionId: UUID,
    preferredChatSessionId: UUID?,
    preferredPaneId: UUID? = nil
  ) -> some View {
    let controller = projectList.sessions.first(where: {
      $0.serverId == serverId && $0.id == anchorSessionId
    }).flatMap { _ in
      ChatControllerCache.shared.existingController(
        sessionId: anchorSessionId,
        serverId: serverId
      )
    }
    let promotion = newChatFlow.flatMap { flow in
      flow.sessionId == anchorSessionId && flow.phase != .settled ? flow : nil
    }
    return WorkspaceScreen(
      sessionId: anchorSessionId,
      serverId: serverId,
      workspaceId: workspaceId,
      preferredChatSessionId: preferredChatSessionId,
      preferredPaneId: preferredPaneId,
      initialController: controller,
      onWorkspaceReady: markPromotedWorkspaceReady,
      // The canonical route lays out under the sheet but does not
      // consume shared transcript presentation state until commit.
      transcriptPresentationRole: promotion == nil ? .foreground : .prewarming,
      composerTextEditorHandoffRole: promotion == nil
        ? .none
        : .promotionDestination,
      composerTextEditorHandoffID: promotion?.id
    )
  }

  private func finishNewChatPromotionIfReady(_ flow: NewChatFlow) {
    guard newChatFlow === flow,
      NewChatPromotionLifecycleContract.canCommit(
        phase: flow.phase,
        canonicalWorkspaceReady: flow.isWorkspaceReady,
        surfaceAnimationFinished: flow.didFinishSurfaceAnimation
      )
    else { return }

    // Home's canonical destination becomes the input owner before either
    // temporary surface is removed. It receives the exact first responder
    // from the sheet, preserving the keyboard through the structural swap.
    flow.phase = .committing
    _ = flow.promotionSurface?.completeStableEditorHandoff()
    flow.promotionSurface?.routeAccessibility(
      through: flow.presentationSession
    )
    commitNewChatPromotion(flow)
  }

  private func commitNewChatPromotion(_ flow: NewChatFlow) {
    let complete = {
      guard newChatFlow === flow else { return }
      flow.promotionWatchdog.cancel()

      // This terminal state removes every promotion-owned surface. The
      // already-mounted Home route switches to a normal foreground
      // workspace, and its composer adopts the exact portaled editor
      // back into the pane hierarchy during the same reconciliation.
      flow.phase = .settled
      let editorSettled = ComposerTextViewHandoffRegistry.settlePromotedEditor(
        id: flow.id
      )
      if !editorSettled { ComposerTextViewHandoffRegistry.cancel(flow.id) }
      flow.promotionSurface?.remove()
      flow.promotionSurface = nil
      presentedNewChatFlow = nil
      newChatFlow = nil
      resetNewChatPresentation()
      IOSNavigationDiagnostics.record(
        "home.newChatPromotion.committed",
        "path=\(navigationPathSummary(path)) editorSettled=\(editorSettled)"
      )
    }

    // The opaque morph still owns visible pixels while UIKit removes the
    // genuine sheet. Its completion reveals Home's ready route and removes
    // the animation replica in one non-animated frame.
    if let presentationSession = flow.presentationSession {
      presentationSession.dismissWithoutAnimation(completion: complete)
    } else {
      complete()
    }
  }

  private func finishNewChatPromotionWithoutAnimation(_ flow: NewChatFlow, reason: String) {
    guard newChatFlow === flow, flow.sessionId != nil else { return }
    IOSNavigationDiagnostics.record("home.newChatPromotion.fallback", "reason=\(reason)")
    flow.promotionWatchdog.cancel()
    pushCanonicalNewChatRoute(flow)
    // Drive the SwiftUI sheet binding directly: a missing UIKit resolver
    // or dismissal completion must never become another wait condition.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      flow.phase = .settled
      if !ComposerTextViewHandoffRegistry.settlePromotedEditor(id: flow.id) {
        ComposerTextViewHandoffRegistry.cancel(flow.id)
      }
      flow.promotionSurface?.remove()
      flow.promotionSurface = nil
      presentedNewChatFlow = nil
      newChatFlow = nil
      resetNewChatPresentation()
    }
  }

  @ViewBuilder func newChatSheet(_ flow: NewChatFlow) -> some View {
    NewChatObservedContent(flow: flow) { liveFlow in
      AnyView(
        NavigationStack(path: $newChatSheetPath) {
          WorkspaceScreen(
            sessionId: nil,
            isNewChatPresentation: true,
            initialComposerFocusRequest: liveFlow.composerFocusRequest,
            onInitialComposerFocusRequestFulfilled:
              liveFlow.consumeFocusRequest,
            onDraftWillStart: { beginNewChatExpansion(liveFlow) },
            onDraftStarted: {
              beginNewChatPromotion($0, flow: liveFlow)
            },
            onDismissNewChat: { cancelNewChat(liveFlow) },
            // Keep the presented hierarchy structurally inert
            // through first send. Changing this role reconciled
            // the source text view before the destination editor
            // existed, which ended the keyboard session.
            transcriptPresentationRole: .foreground,
            onSendAnimationCompleted: {
              markFirstSendAnimationCompleted($0, flow: liveFlow)
            },
            // The sheet flies its own bubble; Home only learns when it
            // has left the composer, to time the expansion.
            onSendAnimationStarted: { _, _ in
              markFirstSendAnimationStarted(liveFlow)
              return false
            },
            composerTextEditorHandoffRole: .promotionSource,
            composerTextEditorHandoffID: liveFlow.id
          )
        }
        .background {
          NewChatPresentationReader { session in
            guard newChatFlow === liveFlow else { return }
            liveFlow.presentationSession = session
            prepareNewChatPromotionSurfaceSoon(liveFlow)
          }
          .frame(width: 0, height: 0)
        }
      )
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.hidden)
    .navigationTransition(
      .zoom(sourceID: Self.newChatTransitionID, in: newChatTransition)
    )
  }

  private func cancelNewChat(_ flow: NewChatFlow) {
    guard newChatFlow === flow else { return }
    if flow.sessionId != nil {
      finishNewChatPromotionWithoutAnimation(flow, reason: "close-during-handoff")
      return
    }
    presentedNewChatFlow = nil
  }

  /// A sheet closed without sending leaves its hidden chrome replica
  /// behind; removed on the next turn, outside UIKit's dismissal callback.
  private func discardPromotionSurface(_ flow: NewChatFlow) {
    guard let surface = flow.promotionSurface else { return }
    flow.promotionSurface = nil
    Task { @MainActor in surface.remove() }
  }

  func handleNewChatSheetDismissed() {
    guard let flow = newChatFlow else {
      resetNewChatPresentation()
      return
    }
    // Promotion keeps its state alive while the expanded live surface is
    // handed to the workspace route. A normal X/gesture dismissal clears
    // only presentation/editor ownership after the system transition;
    // the retained controller still owns the unsent draft value.
    guard flow.phase == .composing else {
      // UIKit is already inside SheetBridge's presentation preference
      // update here. Never force layout or first-responder traversal
      // from this callback; doing so is re-entrant and trips Swift's
      // exclusivity checker. Promotion state is finalized by the
      // dismissal completion and surface animation callbacks.
      return
    }
    ComposerTextViewHandoffRegistry.cancel(flow.id)
    discardPromotionSurface(flow)
    newChatFlow = nil
    resetNewChatPresentation()
  }

  private func resetNewChatPresentation() {
    newChatSheetPath = NavigationPath()
  }

  func shortID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8))
  }

  /// Folder rows add type-erased values to the sheet's own NavigationPath.
  /// Selecting one keeps the draft sheet alive and removes only those
  /// browser pushes.
}
