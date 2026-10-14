import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI

struct SessionScreen: View {
  var controller: SessionController?
  var centerGroup: PaneGroupModel
  var focus: TerminalFocusController = TerminalFocusController()
  var onWorkspaceCommand: ((PaneGroupCommand) -> Bool)?
  var centerTree: SplitNode? = nil
  var primaryLeafId: UUID? = nil
  var activeLeafId: UUID? = nil
  var centerLeafModel: ((UUID) -> PaneGroupModel)? = nil
  var centerPaneTitle: ((PaneDescriptorState) -> String)? = nil
  var sessionStore: SessionStore? = nil
  var splitDragCoordinator: WorkspaceSplitDragCoordinator? = nil
  var onSplitLeaf: ((UUID, SplitEdge) -> Void)? = nil
  var onRenameLeaf: ((UUID, String) -> Void)? = nil
  var onCloseLeaf: ((UUID) -> Void)? = nil
  var openingSplit: WorkspaceSplitOpening? = nil
  var onSplitOpeningFinished: ((WorkspaceSplitOpening) -> Void)? = nil
  var onCenterTreeChanged: ((SplitNode) -> Void)? = nil
  var onCenterTreeLiveChanged: ((SplitNode) -> Void)? = nil
  @State private var attachmentImages: AttachmentImageStore?

  var body: some View {
    centerContent
      .background(
        HostWindowCapture { [weak focus] window in
          focus?.hostWindow = window
        }
        .frame(width: 0, height: 0)
      )
      .onAppear {
        focus.workspaceCommandHandler = onWorkspaceCommand
        focus.centerGroup = centerGroup
        focus.startTypeToFocus()
        installAttachmentImageStoreIfNeeded()
      }
      .onChange(of: controller?.previewCacheNamespace) {
        installAttachmentImageStoreIfNeeded()
      }
      .onDisappear {
        focus.stopTypeToFocus()
        splitDragCoordinator?.dragCancelled()
      }
      .environment(\.attachmentImages, attachmentImages)
  }

  private func installAttachmentImageStoreIfNeeded() {
    guard let controller else {
      attachmentImages = nil
      return
    }
    let namespace = controller.previewCacheNamespace
    guard attachmentImages?.namespace != namespace else { return }
    attachmentImages = AttachmentImageStore(
      namespace: namespace,
      fetch: { [weak controller] source in
        guard let controller else {
          throw SessionControllerError.serverUnavailable
        }
        return try await controller.fileData(for: source)
      },
      fetchPreview: { [weak controller] source in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.filePreview(for: source)
      },
      version: { [weak controller] source in
        guard let controller else {
          throw SessionControllerError.serverUnavailable
        }
        return try await controller.fileVersion(for: source)
      }
    )
  }

  private var centerContent: some View {
    Group {
      if let centerTree, let centerLeafModel {
        WorkspaceSplitView(
          node: centerTree,
          activeLeafId: activeLeafId ?? primaryLeafId,
          groupModel: centerLeafModel,
          paneTitle: centerPaneTitle ?? { $0.displayName },
          sessionStore: sessionStore,
          dragCoordinator: splitDragCoordinator,
          onSplitLeaf: { leafId, edge in onSplitLeaf?(leafId, edge) },
          onRenameLeaf: { leafId, name in onRenameLeaf?(leafId, name) },
          onCloseLeaf: { leafId in onCloseLeaf?(leafId) },
          openingSplit: openingSplit,
          onOpeningFinished: { onSplitOpeningFinished?($0) },
          onTreeChanged: { onCenterTreeChanged?($0) },
          onLiveTreeChanged: { onCenterTreeLiveChanged?($0) }
        )
      } else {
        PaneGroupContent(group: centerGroup)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

}

#if DEBUG
  #Preview("Conversation") {
    SessionScreen(
      controller: .preview(model: .preview()),
      centerGroup: previewPaneGroup(),
    )
    .frame(width: 900, height: 680)
  }

  private func previewPaneGroup() -> PaneGroupModel {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shepherd"))
    let session = ChatSession(projectId: project.id, title: "Preview")
    return PaneGroupModel(
      sessionId: session.id,

      repository: DefaultPaneGroupRepository(store: InMemoryStore()),
      makeContext: { descriptor in
        PaneContext(
          paneId: descriptor.id,
          sessionId: session.id,
          terminalKey: descriptor.terminalKey,
          machine: .local,
          session: session,
          project: project
        )
      }
    )
  }
#endif
