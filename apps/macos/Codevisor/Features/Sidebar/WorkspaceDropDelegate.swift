import SwiftUI

struct WorkspaceDropDelegate: DropDelegate {
  let workspaceID: UUID
  @Binding var draggingWorkspaceID: UUID?
  let moveWorkspace: (UUID, UUID) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    draggingWorkspaceID != nil
  }

  func dropEntered(info: DropInfo) {
    guard let draggingWorkspaceID, draggingWorkspaceID != workspaceID else { return }
    moveWorkspace(draggingWorkspaceID, workspaceID)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggingWorkspaceID = nil
    return true
  }
}
