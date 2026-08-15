import Foundation
import SwiftUI

struct ProjectDropDelegate: DropDelegate {
    let projectID: UUID
    @Binding var draggingProjectID: UUID?
    let moveProject: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingProjectID, draggingProjectID != projectID else { return }
        moveProject(draggingProjectID, projectID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProjectID = nil
        return true
    }
}
