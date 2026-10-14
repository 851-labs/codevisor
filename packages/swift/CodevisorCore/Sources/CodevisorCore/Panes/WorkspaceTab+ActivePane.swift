import Foundation

extension WorkspaceTab {
  public func resolvedActiveLeafId(preferred: UUID?) -> UUID? {
    if let preferred, root.group(id: preferred) != nil { return preferred }
    if root.group(id: activeLeafId) != nil { return activeLeafId }
    return root.allGroups.first?.id
  }
}
