import CodevisorCore
import CodevisorUI
import SwiftUI

extension WorkspaceScreen {
  var activeReviewModel: ReviewPaneModel? {
    guard let pane = activePane, pane.kind == .review else { return nil }
    return reviewPaneModel(for: pane)
  }

  func reviewPaneModel(for pane: PaneDescriptorState) -> ReviewPaneModel {
    let model = ReviewPaneCache.shared.model(for: pane.id) {
      ReviewPaneModel(
        id: pane.id, rootPath: workspaceCwd, machineId: resolvedServerId,
        client: environment.machines.client(for: resolvedServerId),
        preferences: pane.review ?? ReviewPanePreferences())
    }
    let projectBase = resolvedProject?.worktreeBase?.displayName
    if model.projectBase != projectBase { model.projectBase = projectBase }
    model.apply(pane.review ?? ReviewPanePreferences())
    model.onPreferencesChange = { updateReview(pane, preferences: $0) }
    return model
  }

  func convertToReview(_ pane: PaneDescriptorState) {
    guard let workspaceSessionId = paneStorageId else { return }
    var state = panes
    let converted = state.convertNewTabPane(id: pane.id, to: .review, sessionId: workspaceSessionId)
    paneBinding.wrappedValue = state
    if let converted { publishPane(converted) }
  }

  private func updateReview(_ pane: PaneDescriptorState, preferences: ReviewPanePreferences) {
    var state = panes
    guard let index = state.panes.firstIndex(where: { $0.id == pane.id }) else { return }
    state.panes[index].review = preferences
    paneBinding.wrappedValue = state
    publishPane(state.panes[index])
  }
}
