import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
final class ReviewPane: Pane {
  let id: UUID
  let kind: PaneKind = .review
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  let model: ReviewPaneModel

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    model = ReviewPaneModel(
      id: descriptor.id,
      rootPath: context.workspaceRootDirectory ?? context.session?.cwd ?? context.project.folderURL.path,
      machineId: context.machine.id,
      client: context.client ?? CodevisorServerClient(config: context.machine.serverConfig),
      preferences: descriptor.review ?? ReviewPanePreferences(),
      projectBase: context.project.worktreeBase?.displayName)
  }

  func makeView() -> AnyView {
    // The diff is read-only text with no first responder of its own, so a
    // click anywhere in it activates the group.
    AnyView(
      ReviewPaneView(model: model)
        .simultaneousGesture(TapGesture().onEnded { [weak self] in self?.onFocusChanged?(true) }))
  }

  func focus() {}
  // The view polls while mounted, so becoming visible needs no reload.
  func visibilityChanged(_ visible: Bool) {}
  func willDelete() async {}
  func detach() {}
}
