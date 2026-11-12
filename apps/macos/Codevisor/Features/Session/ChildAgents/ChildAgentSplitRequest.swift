import Foundation

struct ChildAgentSplitRequest: Equatable {
  let id = UUID()
  let workspaceId: UUID
  let chatSessionId: UUID
  let chatMachineId: String
  let name: String
}
