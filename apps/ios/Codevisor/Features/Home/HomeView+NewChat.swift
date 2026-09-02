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
    // Host the surface in the PRESENTING (main) window, not the sheet's:
    // zoom presentations can put the sheet in a transient portal window
    // whose layer tree detaches from the render server — an animator
    // started there completes instantly, killing the whole morph.
    guard let presentationSession = flow.presentationSession,
      let presentationWindow = presentationSession.promotionHostWindow,
      let sourceFrame = presentationSession.visibleFrame(in: presentationWindow)
    else {
      // The resolver is installed with the first native-sheet frame, so
      // this should be unreachable in normal interaction. Keeping the
      // draft in the sheet is safer than starting a promotion without
      // exact source geometry.
      IOSNavigationDiagnostics.record(
        "home.newChatPromotion.skipped",
        "reason=sheet-geometry-missing session=\(shortID(sessionId))"
      )
      return
    }
    flow.promotionServerId = session.serverId
    flow.promotionWorkspaceId = workspace.id
    flow.promotionSourceFrame = sourceFrame
    flow.promotionSourceCornerRadius = presentationSession.presentationCornerRadius
    IOSNavigationDiagnostics.record(
      "home.newChatPromotion",
      "workspace=\(shortID(workspace.id)) session=\(shortID(sessionId)) pathBefore=\(navigationPathSummary(path))"
    )

    // Mount the real destination in Home's authoritative stack first. The
    // native sheet still covers this push, so it cannot flash or compete
    // with the system presentation. The morph reveals this exact route.
    path.append(
      .workspace(
        serverId: session.serverId,
        workspaceId: workspace.id,
        anchorSessionId: sessionId,
        preferredChatSessionId: sessionId
      )
    )

    // The replica starts at destination depth so its navigation chrome
    // matches the canonical route. It is destroyed when the morph ends.
    flow.promotionPath = [.workspace]

    // Install directly into the window we just measured. This cannot wait
    // on another SwiftUI appearance lifecycle: Home appeared long ago and
    // late zero-sized backgrounds are not promised a controller callback.
    // The retained pixel overlay covers the sheet before its draft state
    // can reconcile and reveal the already-mounted route underneath.
    let promotionSurface = NewChatPromotionSurface(
      window: presentationWindow,
      sourceFrame: sourceFrame,
      sourceCornerRadius: flow.promotionSourceCornerRadius,
      duration: reduceMotion ? 0 : TranscriptSendAnimationMetrics.duration,
      editorHandoffID: flow.id,
      sourceSnapshot: presentationSession.snapshotView(hidingComposerText: true),
      outgoingSourceEditorFrame: flow.outgoingSourceEditorFrame,
      liveContent: AnyView(
        newChatPromotionContent(flow)
          .environment(environment)
      ),
      onInstalled: { [weak flow] in
        guard let flow else { return }
        promotionSurfaceInstalled(flow)
      },
      onExpanded: { [weak flow] in
        guard let flow, newChatFlow === flow else { return }
        flow.didFinishSurfaceAnimation = true
        finishNewChatPromotionIfReady(flow)
      }
    )
    flow.promotionSurface = promotionSurface
    flow.phase = .animating
    promotionSurface.install()
  }

  private func promotionSurfaceInstalled(_ flow: NewChatFlow) {
    guard newChatFlow === flow, flow.phase == .animating else { return }
    flow.didInstallPromotionSurface = true
    IOSNavigationDiagnostics.record("home.newChatPromotion.liveRouteMounted")
    expandPromotionSurfaceIfReady(flow)
  }

  private func markPromotedWorkspaceReady(_ sessionId: UUID) {
    guard let flow = newChatFlow, flow.sessionId == sessionId else { return }
    flow.isWorkspaceReady = true
    expandPromotionSurfaceIfReady(flow)
    finishNewChatPromotionIfReady(flow)
  }

  private func expandPromotionSurfaceIfReady(_ flow: NewChatFlow) {
    guard newChatFlow === flow,
      flow.didInstallPromotionSurface,
      flow.isWorkspaceReady
    else { return }
    flow.promotionSurface?.expand()
  }

  private func markFirstSendAnimationCompleted(
    _: UserSendAnimationRequest,
    flow: NewChatFlow
  ) {
    guard newChatFlow === flow else { return }
    flow.didFinishFirstSendAnimation = true
    finishNewChatPromotionIfReady(flow)
  }

  private func markFirstSendAnimationStarted(
    _: UserSendAnimationRequest,
    target: TranscriptSendAnimationTarget,
    sessionId: UUID
  ) -> Bool {
    guard let flow = newChatFlow,
      flow.sessionId == sessionId,
      flow.phase == .animating
    else { return false }
    return flow.promotionSurface?.setOutgoingMessageTarget(target) ?? false
  }

  /// Destination construction is deliberately read-only. Normal row taps
  /// populate the cache before pushing, while promoted drafts are registered
  /// there before this route appears.
  func workspaceDestination(
    serverId: String,
    workspaceId: UUID,
    anchorSessionId: UUID,
    preferredChatSessionId: UUID?
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
      initialController: controller,
      onWorkspaceReady: markPromotedWorkspaceReady,
      // The canonical route lays out under the sheet but does not
      // consume shared transcript presentation state until commit.
      transcriptPresentationRole: promotion == nil ? .foreground : .prewarming,
      onSendAnimationStarted: { request, target in
        markFirstSendAnimationStarted(
          request,
          target: target,
          sessionId: anchorSessionId
        )
      },
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

      // This terminal state removes every promotion-owned surface. The
      // already-mounted Home route switches to a normal foreground
      // workspace, and its composer adopts the exact portaled editor
      // back into the pane hierarchy during the same reconciliation.
      flow.phase = .settled
      let editorSettled = ComposerTextViewHandoffRegistry.settlePromotedEditor(
        id: flow.id
      )
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

  @ViewBuilder private func newChatPromotionContent(_ flow: NewChatFlow) -> some View {
    if let sessionId = flow.sessionId,
      let serverId = flow.promotionServerId,
      let workspaceId = flow.promotionWorkspaceId
    {
      let controller = ChatControllerCache.shared.existingController(
        sessionId: sessionId,
        serverId: serverId
      )
      NavigationStack(
        path: Binding(
          get: { flow.promotionPath },
          set: {
            IOSNavigationDiagnostics.record(
              "home.newChatPromotion.path",
              "old=\(flow.promotionPath.count) new=\($0.count)"
            )
            flow.promotionPath = $0
          }
        )
      ) {
        promotionHomeSnapshot(flow)
          .navigationDestination(for: NewChatPromotionRoute.self) { route in
            switch route {
            case .workspace:
              WorkspaceScreen(
                sessionId: sessionId,
                serverId: serverId,
                workspaceId: workspaceId,
                preferredChatSessionId: sessionId,
                initialController: controller,
                // Animation replica only: canonical readiness
                // is reported by Home's real destination.
                transcriptPresentationRole: .foreground,
                onSendAnimationCompleted: {
                  markFirstSendAnimationCompleted($0, flow: flow)
                },
                onSendAnimationStarted: { request, target in
                  markFirstSendAnimationStarted(
                    request,
                    target: target,
                    sessionId: sessionId
                  )
                },
                extendsUnderPromotedHorizontalSafeArea: true,
                // Never compete for the source responder. The
                // canonical route is the handoff destination.
                composerTextEditorHandoffRole: .none
              )
            }
          }
      }
    } else {
      Color(.systemGroupedBackground)
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
            onComposerWillSend: { _, sourceFrame in
              liveFlow.outgoingSourceEditorFrame = sourceFrame
            },
            composerTextEditorHandoffRole: .promotionSource,
            composerTextEditorHandoffID: liveFlow.id
          )
        }
        .background {
          NewChatPresentationReader { session in
            guard newChatFlow === liveFlow else { return }
            liveFlow.presentationSession = session
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
    guard newChatFlow === flow, flow.sessionId == nil else { return }
    presentedNewChatFlow = nil
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
