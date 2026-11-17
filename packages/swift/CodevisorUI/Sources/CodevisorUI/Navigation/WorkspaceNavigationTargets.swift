import Foundation
import Observation

@MainActor
public final class WorkspaceNavigationTargets {
  private var targets: [UUID: WorkspaceNavigationTarget] = [:]
  private var selectedId: UUID?

  public init() {}

  public func isSelected(_ workspaceId: UUID) -> Bool {
    target(for: workspaceId).isSelected
  }

  public func select(_ workspaceId: UUID?) {
    guard workspaceId != selectedId else { return }

    if let selectedId { targets[selectedId]?.isSelected = false }
    selectedId = workspaceId
    if let workspaceId { target(for: workspaceId).isSelected = true }
  }

  private func target(for workspaceId: UUID) -> WorkspaceNavigationTarget {
    if let target = targets[workspaceId] { return target }

    let target = WorkspaceNavigationTarget(isSelected: workspaceId == selectedId)
    targets[workspaceId] = target
    return target
  }
}

@MainActor
@Observable
private final class WorkspaceNavigationTarget {
  var isSelected: Bool

  init(isSelected: Bool) {
    self.isSelected = isSelected
  }
}
