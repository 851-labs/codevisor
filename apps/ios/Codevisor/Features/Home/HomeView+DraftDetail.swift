import CodevisorCore
import CodevisorUI
import SwiftUI

/// New Chat as a page rather than a sheet: the split view's detail on the
/// unfolded display, and the pushed page a fold lands on. Its first send
/// adopts the session in place (`WorkspaceScreen.adoptSession`'s non-sheet
/// branch) and this file turns the route into the workspace it became.
extension HomeView {
  /// The compact pushed draft, reached only by folding while composing.
  func draftDestination(serverId: String?) -> some View {
    detailScreen(for: .newChat(serverId: serverId))
  }

  /// The draft's first send minted a session. The sidebar learns about the
  /// new tab now; the route becomes that workspace only after the send
  /// animation lands, because swapping the screen's chrome (title, role,
  /// New tab) mid-flight relays out the transcript and ends the flight.
  /// The detail identity stays `.draft` either way, so nothing remounts.
  func handleDraftStarted(_ sessionId: UUID) {
    guard let session = projectList.sessions.first(where: { $0.id == sessionId }) else {
      IOSNavigationDiagnostics.record("home.draftDetail.started", "session=\(shortID(sessionId)) missing")
      return
    }
    let workspaceId =
      environment.workspaces.workspaceId(forSession: sessionId)
      ?? ensureWorkspace(for: session).id
    promotedDraftSessionId = sessionId
    pendingDraftPromotion = .workspace(
      serverId: session.serverId,
      workspaceId: workspaceId,
      anchorSessionId: sessionId,
      preferredChatSessionId: sessionId
    )
    bumpWorkspaceRevision()
    IOSNavigationDiagnostics.record(
      "home.draftDetail.started",
      "session=\(shortID(sessionId)) workspace=\(shortID(workspaceId)) mode=\(layoutMode)"
    )
    // The transcript reports the landing; if it never claims the send
    // (reduce motion completes synchronously and still reports), commit
    // after the flight's own bound so the route can't stay a draft.
    let token = pendingDraftPromotion
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_500))
      guard pendingDraftPromotion == token else { return }
      commitPendingDraftPromotion(reason: "watchdog")
    }
  }

  /// The first send's bubble has landed (or the fallback fired): the draft
  /// route becomes its workspace route without an animated transition.
  func commitPendingDraftPromotion(reason: String) {
    guard let route = pendingDraftPromotion else { return }
    pendingDraftPromotion = nil
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      navigation.replaceTop(with: route)
    }
    IOSNavigationDiagnostics.record(
      "home.draftDetail.promoted", "reason=\(reason) path=\(navigationPathSummary(navigation.path))")
  }

  /// The UIKit editor accepted the one-shot focus request.
  func consumeDetailFocusRequest(_ request: UUID) {
    guard detailComposerFocusRequest == request else { return }
    detailComposerFocusRequest = nil
  }
}
