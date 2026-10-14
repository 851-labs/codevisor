import CodevisorCore
import CodevisorUI
import SwiftUI

extension HomeView {
  func draftDestination(serverId: String?) -> some View {
    detailScreen(for: .newChat(serverId: serverId))
  }

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
    IOSNavigationDiagnostics.record(
      "home.draftDetail.started",
      "session=\(shortID(sessionId)) workspace=\(shortID(workspaceId)) mode=\(layoutMode)"
    )
    let token = pendingDraftPromotion
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_500))
      guard pendingDraftPromotion == token else { return }
      commitPendingDraftPromotion(reason: "watchdog")
    }
  }

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

  func consumeDetailFocusRequest(_ request: UUID) {
    guard detailComposerFocusRequest == request else { return }
    detailComposerFocusRequest = nil
  }
}
