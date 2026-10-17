import CodevisorCore
import Foundation
import UIKit
import SwiftUI

extension WorkspaceScreen {
  nonisolated static func diagnosticID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8))
  }
}

struct WorkspaceScreenWorkspaceVersion: Equatable {
  let id: UUID?
  let generation: UInt64
}

extension WorkspaceScreen {
  var workspaceVersion: WorkspaceScreenWorkspaceVersion {
    let entry = workspaceEntry
    return WorkspaceScreenWorkspaceVersion(id: entry?.id, generation: entry?.generation ?? 0)
  }

  var paneStorageId: UUID? {
    resolvedWorkspace?.id ?? activeSessionId
  }

  var legacyPaneSessionIds: [UUID] {
    let workspaceIds = resolvedWorkspace?.chatSessionIds ?? []
    guard let activeSessionId else { return workspaceIds }
    return [activeSessionId] + workspaceIds.filter { $0 != activeSessionId }
  }
}
