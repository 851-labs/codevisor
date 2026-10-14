import Foundation
@testable import CodevisorCore

extension Workspace {
  func tabId(containingPane paneId: UUID) -> UUID? {
    centerTabs.first { $0.root.groupId(containingPane: paneId) != nil }?.id
  }
}
