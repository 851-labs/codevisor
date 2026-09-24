import Foundation
@testable import CodevisorCore

extension Workspace {
  /// The top tab whose split tree holds `paneId`, if any.
  func tabId(containingPane paneId: UUID) -> UUID? {
    centerTabs.first { $0.root.groupId(containingPane: paneId) != nil }?.id
  }
}
