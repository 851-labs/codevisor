import Foundation
import SwiftUI

struct SessionDropDelegate: DropDelegate {
    let sessionID: UUID
    @Binding var draggingSessionID: UUID?
    let moveSession: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingSessionID, draggingSessionID != sessionID else { return }
        moveSession(draggingSessionID, sessionID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingSessionID = nil
        return true
    }
}
