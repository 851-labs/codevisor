import CodevisorCore
import Foundation

struct WorkspaceChrome: Equatable {
  struct RenamedChat: Equatable {
    let id: UUID
    let serverId: String
  }

  let title: String
  let renamedChat: RenamedChat?
  let removesTitle: Bool
  let toolbar: PaneToolbarSource?
  let layoutActions: WorkspaceLayoutActions
}
