import CodevisorCore
import Foundation

final class TranscriptViewerControllers {
  private struct Viewer {
    let controller: SessionController
    let workspaceId: UUID?
  }

  private var viewers: [UUID: Viewer] = [:]

  func controller(paneID: UUID, workspaceId: UUID?, make: () -> SessionController) -> SessionController {
    if let viewer = viewers[paneID] { return viewer.controller }
    let controller = make()
    controller.reportsTurnAnalytics = false
    viewers[paneID] = Viewer(controller: controller, workspaceId: workspaceId)
    return controller
  }

  func release(paneID: UUID) {
    viewers.removeValue(forKey: paneID)?.controller.model?.shutdown()
  }

  func prune(in workspace: Workspace) {
    let open = Set(workspace.allPanes.map(\.id))
    let closed = viewers.filter { $0.value.workspaceId == workspace.id && !open.contains($0.key) }.keys
    for paneID in closed { release(paneID: paneID) }
  }
}

extension SessionStore {
  func transcriptViewer(
    for session: ChatSession, project: Project, paneID: UUID, workspaceId: UUID?
  ) -> SessionController {
    transcriptViewers.controller(paneID: paneID, workspaceId: workspaceId) {
      makeController(for: session, project: project)
    }
  }

  func releaseTranscriptViewer(paneID: UUID, sessionID: UUID) {
    transcriptViewers.release(paneID: paneID)
    transcriptSurfaces.remove(.init(sessionID: sessionID, paneID: paneID))
  }
}
