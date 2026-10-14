import CodevisorCore
import Foundation
import UIKit

struct HomeSidebarSection: Identifiable, Equatable {
  let id: UUID
  let serverId: String
  let name: String
  let machineName: String?
  let anchorSessionId: UUID?
  let status: HomeSessionStatus
  let rows: [HomeSidebarTabRow]

  var displayName: String { name.isEmpty ? "Workspace" : name }

  var workspace: HomeSidebarWorkspaceRef {
    HomeSidebarWorkspaceRef(id: id, serverId: serverId, anchorSessionId: anchorSessionId)
  }
}

struct HomeSidebarWorkspaceRef: Equatable {
  let id: UUID
  let serverId: String
  let anchorSessionId: UUID?
}

struct HomeSidebarTabRow: Identifiable, Equatable {
  enum Icon: Equatable {
    case chat(harnessId: String, fallbackSymbolName: String)
    case terminal
    case browser(favicon: UIImage?)
    case plugin(pluginId: String, paneType: String?)
    case document
    case screenSharing
    case simulator
    case review
    case newTab
  }

  let id: UUID
  let title: String
  let icon: Icon
  let status: HomeSessionStatus
  let chatSessionId: UUID?
  let renamableTabId: UUID?
  var tabId: UUID? = nil
}
